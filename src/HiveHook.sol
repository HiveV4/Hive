// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {Policy, Tier, Guard, Constitution} from "./HiveTypes.sol";
import {IHookSwapEvents} from "./interfaces/IHookSwapEvents.sol";

/// @dev Policy validation and comparison, deployed in HiveObserver to keep this hook under the size limit.
interface IPolicyRules {
    function checkPolicy(Policy calldata m, Policy calldata e, Policy calldata base, bool eExpires)
        external
        view
        returns (bool relaxing);
}

/// @title HiveHook
/// @notice Uniswap v4 hook for the single canonical HIVE pool. It enforces the colony's trading policy:
///         per-swap buy/sell size caps (in HIVE, denominated against the immutable launch supply), directional
///         project fees with up to three size tiers, a dynamic LP fee, the Programmable platform fee, and the market
///         guards: a storm surcharge on sells while the price is far below its reference, a bot-shield surcharge on
///         same-block round trips, and honey hours (temporary lower buy fees). Nothing in this hook can halt or pause
///         trading, and an enabled buy cap can never go below `buyFloorAmount` (a share of launch supply fixed at
///         deployment). All fees are charged in the quote currency (native ETH on mainnet) on the
///         gross quote amount of the swap and accrue as PoolManager ERC-6909 claims held by this hook, with the
///         platform share kept as a separate liability that only the Programmable fee owner can claim.
/// @dev    Hard limits (the "constitution") are immutable. The controller (an operator-run council executor) can only
///         schedule policies that pass the observer's policy rules; stricter policies need `activationDelay` notice;
///         every temporary policy and honey hour expires on block time without any keeper. The bot shield keys on
///         tx.origin, so relayers that
///         route several users in one block can pay it on a second leg; it is a fee, never a block.
///         Supported routes: exact-input buys and sells always; exact-output buys and sells only while no size tiers
///         are active (their fee is a closed-form gross-up, see `_feeGrossUp`). Partial fills of swaps whose fee is
///         taken from the specified side revert instead of over-charging.
contract HiveHook is IHooks, IUnlockCallback, IHookSwapEvents {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------------------------------------ constants
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;
    uint8 public constant MAX_TIERS = 3;
    uint8 public constant SOURCE_BASELINE = 0;
    uint8 public constant SOURCE_CURRENT = 1;
    uint8 public constant SOURCE_PENDING = 2;
    bytes32 internal constant FEE_TSLOT = keccak256("hive.hook.specifiedFee");
    bytes32 internal constant EXTRA_TSLOT = keccak256("hive.hook.surchargePips");
    uint32 public constant MAX_HONEY_HOUR = 2 hours;
    uint32 public constant HONEY_COOLDOWN = 6 hours;
    /// @dev ≈ 5 %: the storm surcharge never reacts to ordinary noise
    uint16 public constant MIN_GUARD_TICKS = 500;

    // ------------------------------------------------------------------------------------------------ immutables
    IPoolManager public immutable poolManager;
    address public immutable token;
    Currency public immutable quote;
    bool public immutable quoteIsCurrency0;
    address public immutable treasury;
    address public immutable programmableFeeOwner;
    int24 public immutable tickSpacing;
    uint256 public immutable launchSupply;
    uint256 public immutable buyFloorAmount;
    uint256 public immutable sellFloorAmount;

    uint24 public immutable platformFeePips;
    uint24 public immutable maxAllInPips;
    uint24 public immutable minLpFeePips;
    uint24 public immutable maxLpFeePips;
    uint16 public immutable buyCapFloorBps;
    uint16 public immutable sellCapFloorBps;
    uint32 public immutable activationDelay;

    address public immutable observer;

    // ------------------------------------------------------------------------------------------------ roles
    address public admin;
    address public pendingAdmin;
    address public controller;

    // ------------------------------------------------------------------------------------------------ pool binding
    PoolId public poolId;
    bool public poolInitialized;

    // ------------------------------------------------------------------------------------------------ policy state
    Policy internal _baseline;
    Policy internal _current;
    Policy internal _pending;
    uint64 public currentExpiresAt; // 0 = no expiry
    uint64 public pendingActivatesAt;
    uint64 public pendingExpiresAt;
    bool public hasPending;
    uint64 public policyVersion;
    mapping(bytes32 => bool) public usedProposal;

    // market guards: reference price (HIVE-price tick) for the storm surcharge
    int24 public refTick;
    uint64 public refAt;
    // honey hour: a short window of lower buy fees (separate capability, only ever relaxes)
    uint64 public honeyStart;
    uint64 public honeyEnd;
    uint24 public honeyBuyFee;
    uint64 internal _prevHoneyEnd;
    // bot shield: last leg per tx.origin, packed as (block number << 1) | isBuy
    mapping(address => uint256) internal _lastLeg;

    // fee accounting (ERC-6909 claims on `quote`, held by this hook)
    uint128 public platformAccrued;
    uint128 public projectAccrued;
    uint256 public platformClaimedTotal;
    uint256 public projectSweptTotal;

    // price accumulator for the observer's TWAP (time-weighted tick, updated at most once per block)
    int64 internal _tickCumulative;
    uint32 internal _lastAccumulate;


    // ------------------------------------------------------------------------------------------------ events
    event ControllerSet(address indexed controller);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferred(address indexed admin);
    event PolicyScheduled(
        uint64 indexed version, bytes32 indexed proposalId, uint64 activatesAt, uint64 expiresAt, bytes32 policyHash
    );
    event PendingPolicyCancelled(uint64 indexed version, bytes32 indexed proposalId);
    event HoneyHourScheduled(bytes32 indexed proposalId, uint64 startsAt, uint64 endsAt, uint24 buyFee);
    event HoneyHourCancelled(bytes32 indexed proposalId, uint64 endedAt);
    event PlatformFeesClaimed(address indexed to, uint256 amount);
    event ProjectFeesSwept(address indexed treasury, uint256 amount);

    // ------------------------------------------------------------------------------------------------ errors
    error NotPoolManager();
    error NotAdmin();
    error NotController();
    error NotFeeOwner();
    error HookNotImplemented();
    error PoolAlreadyBound();
    error PoolNotBound();
    error NotTreasury();
    error WrongPoolKey();
    error InvalidConstitution(uint8 code);
    error InvalidPolicy(uint8 code);
    error ProposalUsed(bytes32 proposalId);
    error StalePolicyVersion(uint64 expected, uint64 actual);
    error ActivationTooSoon(uint64 activatesAt, uint64 earliest);
    error InvalidWindow();
    error NothingPending();
    error PendingAlreadyActive();
    error HoneyHourInvalid(uint8 code);
    error BuyExceedsCap(uint256 amount, uint256 cap);
    error SellExceedsCap(uint256 amount, uint256 cap);
    error ExactOutputUnavailableWithTiers();
    error PartialFillUnsupported();
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller || controller == address(0)) revert NotController();
        _;
    }

    struct Wiring {
        IPoolManager poolManager;
        address token;
        Currency quote;
        address treasury;
        address programmableFeeOwner;
        address admin;
        address controller;
        address observer;
        int24 tickSpacing;
        uint256 launchSupply;
    }

    constructor(Wiring memory w, Constitution memory c, Policy memory baseline) {
        if (
            address(w.poolManager) == address(0) || w.token == address(0) || w.treasury == address(0)
                || w.programmableFeeOwner == address(0) || w.admin == address(0) || w.observer == address(0)
        ) revert ZeroAddress();
        if (Currency.unwrap(w.quote) == w.token) revert InvalidConstitution(0);
        _validateConstitution(c, w.launchSupply);

        poolManager = w.poolManager;
        token = w.token;
        quote = w.quote;
        quoteIsCurrency0 = uint160(Currency.unwrap(w.quote)) < uint160(w.token);
        treasury = w.treasury;
        programmableFeeOwner = w.programmableFeeOwner;
        tickSpacing = w.tickSpacing;
        launchSupply = w.launchSupply;
        buyFloorAmount = w.launchSupply * c.buyCapFloorBps / BPS;
        sellFloorAmount = w.launchSupply * c.sellCapFloorBps / BPS;

        platformFeePips = c.platformFeePips;
        maxAllInPips = c.maxAllInPips;
        minLpFeePips = c.minLpFeePips;
        maxLpFeePips = c.maxLpFeePips;
        buyCapFloorBps = c.buyCapFloorBps;
        sellCapFloorBps = c.sellCapFloorBps;
        activationDelay = c.activationDelay;

        observer = w.observer;

        admin = w.admin;
        controller = w.controller;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        // The baseline is checked against the constitution by the observer when it is wired to this hook
        // (HiveObserver.initialize), atomically inside the launch graph and before the pool exists.
        _storePolicy(_baseline, baseline);
        _storePolicy(_current, baseline);
        emit ControllerSet(w.controller);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============================================================================================ v4 callbacks

    /// @notice Binds the hook to exactly one pool: native/HIVE (sorted), dynamic LP fee, configured tick spacing,
    ///         initialized by the treasury during the launch graph.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (poolInitialized) revert PoolAlreadyBound();
        if (sender != treasury) revert NotTreasury();
        (Currency c0, Currency c1) = quoteIsCurrency0 ? (quote, Currency.wrap(token)) : (Currency.wrap(token), quote);
        if (
            !(key.currency0 == c0) || !(key.currency1 == c1) || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert WrongPoolKey();
        TickMath.getTickAtSqrtPrice(sqrtPriceX96); // reverts on an out-of-range price
        poolId = key.toId();
        poolInitialized = true;
        _lastAccumulate = uint32(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _accumulate();
        bool isBuy = params.zeroForOne == quoteIsCurrency0;
        bool exactIn = params.amountSpecified < 0;
        Policy storage p = _effectivePolicyRef();

        if (!exactIn && p.tierCount != 0) revert ExactOutputUnavailableWithTiers();
        _tstore(EXTRA_TSLOT, _guards(p.guard, isBuy, sender));

        int128 specifiedFee;
        if (isBuy == exactIn) {
            // The quote currency is the specified side: buy exact-in (gross input) or sell exact-out (net output).
            (uint256 total, uint256 platformPart, uint24 rate) = exactIn
                ? _feeOnGross(uint256(-params.amountSpecified), p, true, sender)
                : _feeGrossUp(uint256(params.amountSpecified), p, false, sender);
            if (total != 0) {
                _accrue(total, platformPart);
                poolManager.mint(address(this), quote.toId(), total);
                specifiedFee = int128(int256(total));
                _emitHookSwap(sender, total, rate);
            }
            _tstore(FEE_TSLOT, total);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedFee, 0), p.lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool isBuy = params.zeroForOne == quoteIsCurrency0;
        bool exactIn = params.amountSpecified < 0;
        Policy storage p = _effectivePolicyRef();

        (int128 q, int128 h) = quoteIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 hiveAmount = uint256(int256(h < 0 ? -h : h));

        // Size caps on the actual HIVE amount moved by the pool, for every route. Colony swaps (treasury buybacks and
        // the launch buy) have their own limits in the treasury.
        if (isBuy) {
            if (p.buyCapOn && sender != treasury) {
                uint256 cap = _effectiveBuyCap(p.buyCap);
                if (hiveAmount > cap) revert BuyExceedsCap(hiveAmount, cap);
            }
        } else if (p.sellCapOn && hiveAmount > p.sellCap) {
            revert SellExceedsCap(hiveAmount, p.sellCap);
        }

        int128 unspecifiedFee;
        if (isBuy == exactIn) {
            // Fee was taken from the specified side in beforeSwap; require the pool to have filled it completely.
            uint256 fee = _tload(FEE_TSLOT);
            uint256 poolQuote = uint256(int256(q < 0 ? -q : q));
            uint256 expected = exactIn ? uint256(-params.amountSpecified) - fee : uint256(params.amountSpecified) + fee;
            if (poolQuote != expected) revert PartialFillUnsupported();
        } else {
            // Quote is the unspecified side: buy exact-out (pool input, gross-up) or sell exact-in (pool output).
            (uint256 total, uint256 platformPart, uint24 rate) = exactIn
                ? _feeOnGross(uint256(int256(q)), p, false, sender)
                : _feeGrossUp(uint256(int256(-q)), p, true, sender);
            if (total != 0) {
                _accrue(total, platformPart);
                poolManager.mint(address(this), quote.toId(), total);
                unspecifiedFee = int128(int256(total));
                _emitHookSwap(sender, total, rate);
            }
        }
        return (IHooks.afterSwap.selector, unspecifiedFee);
    }

    // Disabled callbacks: present so every IHooks entry point is implemented, unreachable through permissions.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ============================================================================================ fee claims

    /// @notice Pays the accrued Programmable platform fee to a destination chosen by the Programmable fee owner.
    function claimPlatformFees(address to) external returns (uint256 amount) {
        if (msg.sender != programmableFeeOwner) revert NotFeeOwner();
        if (to == address(0)) revert ZeroAddress();
        amount = platformAccrued;
        if (amount == 0) return 0;
        platformAccrued = 0;
        platformClaimedTotal += amount;
        poolManager.unlock(abi.encode(to, amount));
        emit PlatformFeesClaimed(to, amount);
    }

    /// @notice Moves accrued project fees to the treasury. Permissionless; the destination is immutable.
    function sweepProjectFees() external returns (uint256 amount) {
        amount = projectAccrued;
        if (amount == 0) return 0;
        projectAccrued = 0;
        projectSweptTotal += amount;
        poolManager.unlock(abi.encode(treasury, amount));
        emit ProjectFeesSwept(treasury, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, to, amount);
        return "";
    }

    // ============================================================================================ governance

    function setController(address newController) external onlyAdmin {
        controller = newController;
        emit ControllerSet(newController);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(msg.sender);
    }

    /// @notice Schedules a complete policy. `expiresAt == 0` makes it standing; otherwise it falls back to the
    ///         baseline at `expiresAt`. Any policy stricter for traders than both the policy in force now and the
    ///         policy that would follow it needs `activationDelay` notice.
    function schedulePolicy(
        Policy calldata p,
        uint64 activatesAt,
        uint64 expiresAt,
        bytes32 proposalId,
        uint64 expectedVersion
    ) external onlyController {
        _consumeProposal(proposalId, expectedVersion);
        _promote();
        if (activatesAt < block.timestamp || (expiresAt != 0 && expiresAt <= activatesAt)) revert InvalidWindow();
        Policy memory m = p;
        (Policy storage e, uint8 source) = _effectivePolicyRefWithSource();
        bool eExpires = source == SOURCE_BASELINE ? false : (source == SOURCE_CURRENT ? currentExpiresAt != 0 : pendingExpiresAt != 0);
        // validation (reverts InvalidPolicy) and the stricter/relaxing comparison live in the observer
        bool relaxing = IPolicyRules(observer).checkPolicy(p, e, _baseline, eExpires);
        if (!relaxing && activatesAt < block.timestamp + activationDelay) {
            revert ActivationTooSoon(activatesAt, uint64(block.timestamp + activationDelay));
        }

        _storePolicy(_pending, m);
        pendingActivatesAt = activatesAt;
        pendingExpiresAt = expiresAt;
        hasPending = true;
        emit PolicyScheduled(policyVersion, proposalId, activatesAt, expiresAt, keccak256(abi.encode(m)));
    }

    /// @notice Cancels a pending policy that has not activated yet. Callable by the controller or the admin.
    function cancelPendingPolicy(bytes32 proposalId, uint64 expectedVersion) external {
        if (msg.sender != admin && (msg.sender != controller || controller == address(0))) revert NotController();
        _consumeProposal(proposalId, expectedVersion);
        if (!hasPending) revert NothingPending();
        if (block.timestamp >= pendingActivatesAt) revert PendingAlreadyActive();
        hasPending = false;
        emit PendingPolicyCancelled(policyVersion, proposalId);
    }

    /// @notice Schedules a honey hour: buys pay at most `buyFee` as project fee. It only ever relaxes, so it may start
    ///         at once; at most `MAX_HONEY_HOUR` long, one at a time, `HONEY_COOLDOWN` after the previous one ended.
    function scheduleHoneyHour(uint64 startsAt, uint32 duration, uint24 buyFee, bytes32 proposalId) external onlyController {
        if (usedProposal[proposalId] || proposalId == bytes32(0)) revert ProposalUsed(proposalId);
        usedProposal[proposalId] = true;
        if (duration == 0 || duration > MAX_HONEY_HOUR || buyFee >= PIPS) revert HoneyHourInvalid(1);
        if (startsAt < block.timestamp) revert HoneyHourInvalid(2);
        if (block.timestamp < honeyEnd) revert HoneyHourInvalid(3); // one pending or running honey hour at a time
        if (honeyEnd != 0 && startsAt < uint256(honeyEnd) + HONEY_COOLDOWN) revert HoneyHourInvalid(4);
        _prevHoneyEnd = honeyEnd;
        honeyStart = startsAt;
        honeyEnd = startsAt + duration;
        honeyBuyFee = buyFee;
        emit HoneyHourScheduled(proposalId, startsAt, startsAt + duration, buyFee);
    }

    /// @notice Ends a scheduled or running honey hour early. Callable by the controller or the admin.
    function cancelHoneyHour(bytes32 proposalId) external {
        if (msg.sender != admin && (msg.sender != controller || controller == address(0))) revert NotController();
        if (usedProposal[proposalId] || proposalId == bytes32(0)) revert ProposalUsed(proposalId);
        usedProposal[proposalId] = true;
        if (block.timestamp >= honeyEnd) revert HoneyHourInvalid(5);
        if (block.timestamp < honeyStart) {
            // never started: restore the previous end so the cooldown anchor is unchanged
            honeyStart = _prevHoneyEnd;
            honeyEnd = _prevHoneyEnd;
        } else {
            honeyEnd = uint64(block.timestamp);
        }
        emit HoneyHourCancelled(proposalId, honeyEnd);
    }

    // ============================================================================================ observation

    /// @notice Cumulative time-weighted tick up to now (for TWAPs computed by the observer).
    function cumulativeTick() external view returns (int64 cumulative, uint32 timestamp) {
        if (!poolInitialized) revert PoolNotBound();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        cumulative = _tickCumulative + int64(tick) * int64(uint64(uint32(block.timestamp) - _lastAccumulate));
        timestamp = uint32(block.timestamp);
    }

    // ============================================================================================ views

    function baselinePolicy() external view returns (Policy memory) {
        return _baseline;
    }

    function pendingPolicy() external view returns (Policy memory) {
        return _pending;
    }

    /// @notice Policy in force right now, which slot it comes from, and when it stops applying (0 = standing).
    function effectivePolicy() external view returns (Policy memory policy, uint8 source, uint64 expiresAt) {
        (Policy storage p, uint8 s) = _effectivePolicyRefWithSource();
        policy = p;
        source = s;
        expiresAt = source == SOURCE_CURRENT ? currentExpiresAt : (source == SOURCE_PENDING ? pendingExpiresAt : 0);
    }

    /// @notice Effective per-swap buy cap right now: (enabled, amount). Never below `buyFloorAmount`.
    function effectiveBuyCap() external view returns (bool enabled, uint256 amount) {
        Policy storage p = _effectivePolicyRef();
        if (!p.buyCapOn) return (false, type(uint256).max);
        return (true, _effectiveBuyCap(p.buyCap));
    }

    function honeyHourActive() public view returns (bool) {
        return block.timestamp >= honeyStart && block.timestamp < honeyEnd;
    }

    /// @notice Fee preview with exactly the arithmetic used during swaps.
    /// @param amount exact-in: gross quote input (buy) or pool quote output (sell);
    ///               exact-out: pool quote input (buy) or desired net quote output (sell).
    /// @return total hook fee (platform + project) in quote wei, platform share, effective hook rate (pips)
    function previewHookFee(bool isBuy, bool exactIn, uint256 amount, address sender)
        external
        view
        returns (uint256 total, uint256 platformPart, uint24 rate)
    {
        Policy storage p = _effectivePolicyRef();
        if (!exactIn && p.tierCount != 0) revert ExactOutputUnavailableWithTiers();
        return exactIn ? _feeOnGross(amount, p, isBuy, sender) : _feeGrossUp(amount, p, isBuy, sender);
    }

    function constitution() external view returns (Constitution memory) {
        return Constitution({
            platformFeePips: platformFeePips,
            maxAllInPips: maxAllInPips,
            minLpFeePips: minLpFeePips,
            maxLpFeePips: maxLpFeePips,
            buyCapFloorBps: buyCapFloorBps,
            sellCapFloorBps: sellCapFloorBps,
            activationDelay: activationDelay
        });
    }

    // Programmable platform-fee readbacks.
    function programmableHundredthsOfBip() external view returns (uint24) {
        return platformFeePips;
    }

    /// @notice Hash of the platform-fee policy this hook implements:
    ///         (rate pips, denominator, basis = gross quote volume, fee currency = quote, rounding = floor,
    ///          accounting = additive, claim = fee-owner-selected recipient, fee owner).
    function programmableFeePolicyHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                "hive.platform-fee.v1",
                uint256(platformFeePips),
                PIPS,
                "executed-gross-declared-quote",
                Currency.unwrap(quote),
                "floor",
                "additive-platform-share",
                "claim-authority-selected-recipient",
                programmableFeeOwner
            )
        );
    }

    // ============================================================================================ internals: fees

    function _projectPips(Policy storage p, bool isBuy, uint256 grossQuote, address sender)
        internal
        view
        returns (uint256 pips)
    {
        if (sender == treasury) return 0; // colony buybacks pay only the platform fee (no fee recursion)
        pips = isBuy ? p.buyFee : p.sellFee;
        uint8 n = p.tierCount;
        for (uint8 i; i < n; ++i) {
            Tier storage t = p.tiers[i];
            if (grossQuote < t.minQuote) break;
            pips = isBuy ? t.buyFee : t.sellFee;
        }
    }

    /// @dev Project fee of a live swap: the policy fee (tiers included), lowered to the honey-hour fee on buys during
    ///      a honey hour, plus this swap's guard surcharges, clamped so platform + project + LP stay within the ceiling.
    function _swapPips(Policy storage p, bool isBuy, uint256 grossQuote, address sender) internal view returns (uint256 x) {
        x = _projectPips(p, isBuy, grossQuote, sender);
        if (sender == treasury) return x;
        if (isBuy && honeyHourActive() && honeyBuyFee < x) x = honeyBuyFee;
        x += _tload(EXTRA_TSLOT);
        uint256 room = maxAllInPips - platformFeePips - p.lpFee; // validated non-negative at scheduling
        if (x > room) x = room;
    }

    /// @dev Fee on a known gross quote amount: platform = floor(gross*platform/1e6), project = floor(gross*project/1e6).
    function _feeOnGross(uint256 gross, Policy storage p, bool isBuy, address sender)
        internal
        view
        returns (uint256 total, uint256 platformPart, uint24 rate)
    {
        uint256 x = _swapPips(p, isBuy, gross, sender);
        platformPart = gross * platformFeePips / PIPS;
        total = platformPart + gross * x / PIPS;
        rate = uint24(platformFeePips + x);
    }

    /// @dev Exact-output fee (no tiers allowed): the fee is grossed up from the net pool-side amount so that
    ///      gross = net + total and total = ceil(net * r / (1e6 - r)), i.e. floor(gross*r/1e6) <= total <=
    ///      floor(gross*r/1e6) + 1. Closed form, never circular.
    function _feeGrossUp(uint256 net, Policy storage p, bool isBuy, address sender)
        internal
        view
        returns (uint256 total, uint256 platformPart, uint24 rate)
    {
        uint256 r = platformFeePips + _swapPips(p, isBuy, 0, sender);
        total = FullMath.mulDivRoundingUp(net, r, PIPS - r);
        platformPart = (net + total) * platformFeePips / PIPS;
        rate = uint24(r);
    }

    function _accrue(uint256 total, uint256 platformPart) internal {
        platformAccrued += uint128(platformPart);
        projectAccrued += uint128(total - platformPart);
    }

    function _emitHookSwap(address sender, uint256 fee, uint24 rate) internal {
        int128 paid = -int128(int256(fee));
        if (quoteIsCurrency0) emit HookSwap(poolId, sender, paid, 0, rate);
        else emit HookSwap(poolId, sender, 0, paid, rate);
    }

    /// @dev The policy rules already refuse caps below the floor; this keeps the floor even for a stored policy.
    function _effectiveBuyCap(uint128 cap) internal view returns (uint256) {
        return cap < buyFloorAmount ? buyFloorAmount : cap;
    }

    function _tstore(bytes32 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    // ============================================================================================ internals: guards

    /// @dev HIVE price as a tick: up means HIVE got dearer in the quote currency.
    function _hiveTick() internal view returns (int256) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return quoteIsCurrency0 ? -int256(tick) : int256(tick);
    }

    /// @dev Before a swap: renews the reference price when it is older than `refWindow`, then returns this swap's
    ///      surcharge in pips (storm on sells far below the reference; bot shield on the second leg of a same-block
    ///      round trip by the same tx.origin). Colony swaps (treasury) pay neither.
    function _guards(Guard storage g, bool isBuy, address sender) internal returns (uint256 extra) {
        if (g.refWindow != 0) {
            int256 h = _hiveTick();
            if (refAt == 0 || block.timestamp >= uint256(refAt) + g.refWindow) {
                refTick = int24(h);
                refAt = uint64(block.timestamp);
            } else if (!isBuy && g.stormDropTicks != 0 && refTick - h >= int256(uint256(g.stormDropTicks))) {
                extra = g.stormFee;
            }
        }
        if (g.botFee != 0 && sender != treasury) {
            uint256 prev = _lastLeg[tx.origin];
            uint256 side = isBuy ? 1 : 0;
            if (prev >> 1 == block.number && prev & 1 != side) extra += g.botFee;
            _lastLeg[tx.origin] = (block.number << 1) | side;
        }
        if (sender == treasury) extra = 0;
    }

    // ============================================================================================ internals: policy

    function _effectivePolicyRef() internal view returns (Policy storage p) {
        (p,) = _effectivePolicyRefWithSource();
    }

    function _effectivePolicyRefWithSource() internal view returns (Policy storage p, uint8 source) {
        if (hasPending && block.timestamp >= pendingActivatesAt) {
            if (pendingExpiresAt != 0 && block.timestamp >= pendingExpiresAt) return (_baseline, SOURCE_BASELINE);
            return (_pending, SOURCE_PENDING);
        }
        if (currentExpiresAt != 0 && block.timestamp >= currentExpiresAt) return (_baseline, SOURCE_BASELINE);
        return (_current, SOURCE_CURRENT);
    }

    function _promote() internal {
        if (hasPending && block.timestamp >= pendingActivatesAt) {
            _copyPolicy(_current, _pending);
            currentExpiresAt = pendingExpiresAt;
            hasPending = false;
        }
    }

    function _consumeProposal(bytes32 proposalId, uint64 expectedVersion) internal {
        if (proposalId == bytes32(0) || usedProposal[proposalId]) revert ProposalUsed(proposalId);
        if (expectedVersion != policyVersion) revert StalePolicyVersion(expectedVersion, policyVersion);
        usedProposal[proposalId] = true;
        policyVersion++;
    }

    function _storePolicy(Policy storage dst, Policy memory src) internal {
        dst.buyCapOn = src.buyCapOn;
        dst.sellCapOn = src.sellCapOn;
        dst.buyCap = src.buyCap;
        dst.sellCap = src.sellCap;
        dst.buyFee = src.buyFee;
        dst.sellFee = src.sellFee;
        dst.lpFee = src.lpFee;
        dst.tierCount = src.tierCount;
        for (uint8 i; i < MAX_TIERS; ++i) {
            dst.tiers[i] = src.tiers[i];
        }
        dst.guard = src.guard;
    }

    function _copyPolicy(Policy storage dst, Policy storage src) internal {
        _storePolicy(dst, src);
    }

    function _validateConstitution(Constitution memory c, uint256 supply) internal pure {
        if (supply == 0) revert InvalidConstitution(1);
        if (c.platformFeePips > 10_000) revert InvalidConstitution(2); // never above 1%
        if (c.maxAllInPips > 100_000 || c.maxAllInPips <= uint256(c.platformFeePips) + c.minLpFeePips) {
            revert InvalidConstitution(3);
        }
        if (c.minLpFeePips > c.maxLpFeePips || c.maxLpFeePips > LPFeeLibrary.MAX_LP_FEE) revert InvalidConstitution(4);
        if (c.buyCapFloorBps < 100 || c.buyCapFloorBps > BPS) revert InvalidConstitution(5); // >= 1%
        if (c.sellCapFloorBps < 10 || c.sellCapFloorBps > BPS) revert InvalidConstitution(6); // >= 0.1%
        if (c.activationDelay < 60) revert InvalidConstitution(7);
    }

    // ============================================================================================ internals: oracle

    function _accumulate() internal {
        uint32 nowTs = uint32(block.timestamp);
        uint32 last = _lastAccumulate;
        if (nowTs == last) return;
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        _tickCumulative += int64(tick) * int64(uint64(nowTs - last));
        _lastAccumulate = nowTs;
    }
}
