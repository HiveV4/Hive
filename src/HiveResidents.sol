// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title HiveResidents
/// @notice Resident vault. Depositing at least `MIN_DEPOSIT` HIVE opens a resident position (one illustrated bee).
///         The deposit is backing, never burned or lent out: `leave` always returns exactly the deposited HIVE to the
///         position owner. Positions are deliberately non-transferable in this version (no marketplace, no transfer
///         accounting edge cases); one wallet may hold many positions.
///
///         Honey rewards are native ETH streamed by the treasury over funding epochs and shared pro rata to deposited
///         HIVE using constant-time reward-per-share accounting. Rewards that accrue while the vault is empty are kept
///         as `unallocatedScaled` and re-streamed later — never lost, never claimable by anyone else.
///
///         This contract has no owner and no admin. Nobody — treasury, council, executor, admin — can move backing or
///         accrued rewards; the only inbound authority is the treasury's right to add (never remove) funding.
contract HiveResidents {
    uint256 internal constant SCALE = 1e18; // rate scaling
    uint256 internal constant RPS_SCALE = 1e36; // reward-per-share scaling

    IERC20Min public immutable token;
    address public immutable treasury;
    uint256 public immutable MIN_DEPOSIT;
    uint32 public immutable MIN_EPOCH;
    uint32 public immutable MAX_EPOCH;
    uint32 public immutable RESTREAM_EPOCH;

    struct Position {
        address owner;
        uint64 openedAt;
        uint128 amount;
        uint256 rpsPaid;
        uint256 accrued;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;
    uint256 public totalShares;
    uint256 public openPositions;

    uint256 public rateScaled; // wei per second * SCALE
    uint64 public periodFinish;
    uint64 public lastUpdate;
    uint256 public rewardPerShare; // * RPS_SCALE
    uint256 public unallocatedScaled; // wei * SCALE accrued while totalShares == 0
    uint256 public totalFunded;
    uint256 public totalClaimed;

    uint256 private _lock = 1;

    event Joined(uint256 indexed id, address indexed owner, uint256 amount);
    event Left(uint256 indexed id, address indexed owner, uint256 amount, uint256 reward);
    event Claimed(uint256 indexed id, address indexed owner, uint256 reward);
    event HoneyFunded(uint256 amount, uint256 restreamed, uint32 duration, uint64 periodFinish);

    error NotTreasury();
    error NotOwner();
    error BelowMinimum();
    error BadEpoch();
    error NothingToStream();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address token_, address treasury_, uint256 minDeposit, uint32 minEpoch, uint32 maxEpoch, uint32 restreamEpoch) {
        require(token_ != address(0) && treasury_ != address(0) && minDeposit > 0, "config");
        require(minEpoch > 0 && minEpoch <= restreamEpoch && restreamEpoch <= maxEpoch, "epochs");
        token = IERC20Min(token_);
        treasury = treasury_;
        MIN_DEPOSIT = minDeposit;
        MIN_EPOCH = minEpoch;
        MAX_EPOCH = maxEpoch;
        RESTREAM_EPOCH = restreamEpoch;
        lastUpdate = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------------------------------ residents

    /// @notice Opens a resident position backed by `amount` HIVE (>= MIN_DEPOSIT).
    function join(uint256 amount) external nonReentrant returns (uint256 id) {
        if (amount < MIN_DEPOSIT) revert BelowMinimum();
        _update();
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 received = token.balanceOf(address(this)) - before;
        if (received < MIN_DEPOSIT) revert BelowMinimum();
        id = nextId++;
        positions[id] = Position({
            owner: msg.sender,
            openedAt: uint64(block.timestamp),
            amount: uint128(received),
            rpsPaid: rewardPerShare,
            accrued: 0
        });
        totalShares += received;
        openPositions++;
        emit Joined(id, msg.sender, received);
    }

    /// @notice Closes a position: returns the full HIVE backing and all accrued ETH rewards to the owner.
    function leave(uint256 id) external nonReentrant returns (uint256 amount, uint256 reward) {
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        _update();
        reward = _settle(pos);
        amount = pos.amount;
        totalShares -= amount;
        openPositions--;
        delete positions[id];
        totalClaimed += reward;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        _sendEth(msg.sender, reward);
        emit Left(id, msg.sender, amount, reward);
    }

    /// @notice Pays accrued ETH rewards of a position to its owner.
    function claim(uint256 id) external nonReentrant returns (uint256 reward) {
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        _update();
        reward = _settle(pos);
        pos.accrued = 0;
        totalClaimed += reward;
        _sendEth(msg.sender, reward);
        emit Claimed(id, msg.sender, reward);
    }

    // ------------------------------------------------------------------------------------------ funding

    /// @notice Adds a funded epoch. Remaining un-streamed rewards and any unallocated amount are folded into the new
    ///         stream over `duration`. Only the treasury may add funding; nothing can remove it.
    function fund(uint32 duration) external payable nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        if (duration < MIN_EPOCH || duration > MAX_EPOCH) revert BadEpoch();
        _restart(msg.value, duration);
    }

    /// @notice Re-streams rewards that accrued while nobody lived in the vault. Permissionless, only when no stream is
    ///         running and at least one resident exists.
    function restream() external nonReentrant {
        if (block.timestamp < periodFinish || totalShares == 0 || unallocatedScaled < SCALE) revert NothingToStream();
        _restart(0, RESTREAM_EPOCH);
    }

    // ------------------------------------------------------------------------------------------ views

    function pendingReward(uint256 id) external view returns (uint256) {
        Position storage pos = positions[id];
        if (pos.owner == address(0)) return 0;
        (uint256 rps,) = _projected();
        return pos.accrued + FullMath.mulDiv(pos.amount, rps - pos.rpsPaid, RPS_SCALE);
    }

    /// @notice Rewards (wei) that accrued while the vault was empty, including the not yet checkpointed part.
    function unallocatedRewards() external view returns (uint256) {
        (, uint256 u) = _projected();
        return u / SCALE;
    }

    /// @notice ETH the vault must keep for current and future obligations (streamed-but-unclaimed + still streaming).
    function remainingStream() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rateScaled / SCALE;
    }

    // ------------------------------------------------------------------------------------------ internals

    function _restart(uint256 added, uint32 duration) internal {
        _update();
        uint256 leftoverScaled;
        if (block.timestamp < periodFinish) leftoverScaled = (periodFinish - block.timestamp) * rateScaled;
        uint256 totalScaled = added * SCALE + leftoverScaled + unallocatedScaled;
        uint256 restreamed = unallocatedScaled / SCALE;
        unallocatedScaled = 0;
        rateScaled = totalScaled / duration;
        // rounding remainder of the division stays unallocated, never over-promised
        unallocatedScaled = totalScaled - rateScaled * duration;
        lastUpdate = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + duration);
        totalFunded += added;
        emit HoneyFunded(added, restreamed, duration, periodFinish);
    }

    function _projected() internal view returns (uint256 rps, uint256 unallocScaled) {
        rps = rewardPerShare;
        unallocScaled = unallocatedScaled;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t > lastUpdate) {
            uint256 streamedScaled = (t - lastUpdate) * rateScaled;
            if (totalShares == 0) unallocScaled += streamedScaled;
            else rps += FullMath.mulDiv(streamedScaled, RPS_SCALE / SCALE, totalShares);
        }
    }

    function _update() internal {
        (rewardPerShare, unallocatedScaled) = _projected();
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t > lastUpdate) lastUpdate = uint64(t);
    }

    function _settle(Position storage pos) internal returns (uint256 reward) {
        reward = pos.accrued + FullMath.mulDiv(pos.amount, rewardPerShare - pos.rpsPaid, RPS_SCALE);
        pos.rpsPaid = rewardPerShare;
        pos.accrued = reward;
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
