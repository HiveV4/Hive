// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {Policy} from "./HiveTypes.sol";

interface IHiveTokenT {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function burn(uint256) external;
    function LAUNCH_SUPPLY() external view returns (uint256);
}

interface IHiveHookT {
    function token() external view returns (address);
    function treasury() external view returns (address);
    function tickSpacing() external view returns (int24);
    function platformFeePips() external view returns (uint24);
    function sweepProjectFees() external returns (uint256);
    function observer() external view returns (address);
    function effectivePolicy() external view returns (Policy memory policy, uint8 source, uint64 expiresAt);
}

interface IHiveObserverT {
    function twapTick(uint32 minAge) external view returns (bool ok, int24 avgTick, uint32 span);
    function twapWindow() external view returns (uint32);
}

interface IHiveResidentsT {
    function token() external view returns (address);
    function treasury() external view returns (address);
    function fund(uint32 duration) external payable;
}

/// @title HiveTreasury
/// @notice The colony pantry. Receives project fees from the hook and LP fees from its own positions, splits every
///         inflow into five budgets (liquidity, burn, honey, operations, uncommitted reserve) by the allocation in
///         force when the inflow is accounted, and spends only through narrowly scoped, bounded actions:
///         slippage-limited buybacks (burn or hold), liquidity growth into the canonical pool, honey funding epochs
///         for residents, and rate-limited operations payouts to one immutable recipient.
///
///         Liquidity positions are owned by this contract and there is no function that removes liquidity: principal
///         is permanently locked; only accrued LP fees can be collected (permissionless). There is no withdraw, no
///         arbitrary call, no delegatecall, no approval, no upgrade. The executor (council keeper key) can only call
///         the actions below; the admin can only rotate or freeze the executor.
contract HiveTreasury is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    /// @notice The launch buy (ETH sent with the launch transaction) may buy at most 5% of the launch supply.
    uint256 public constant MAX_LAUNCH_BUY_BPS = 500;
    bytes32 public constant LAUNCH_SALT = keccak256("hive.position.launch");
    bytes32 public constant GROWTH_SALT = keccak256("hive.position.growth");

    enum Budget {
        Lp,
        Burn,
        Honey,
        Ops,
        Reserve
    }

    enum Op {
        Seed,
        Buy,
        AddLiquidity,
        Collect
    }

    struct Allocation {
        uint16 lp;
        uint16 burn;
        uint16 honey;
        uint16 ops;
        uint16 reserve;
    }

    struct Limits {
        uint256 maxBuybackPerBatch; // wei
        uint32 minBuybackInterval; // seconds between buyback batches
        uint256 maxLiquidityPerBatch; // wei of LP budget per growth batch
        uint16 maxSlippageBps; // min-out must be within this of the TWAP-implied output
        int24 maxTickDeviation; // spot vs TWAP tolerance for liquidity adds
        uint16 maxOpsShareBps; // ceiling of the ops allocation share
        uint256 maxOpsPerWindow; // wei paid to ops per window
        uint32 opsWindow;
        uint32 minHoneyEpoch;
        uint32 maxHoneyEpoch;
    }

    // immutables
    IPoolManager public immutable poolManager;
    address public immutable deployer;
    address public immutable opsRecipient;
    uint256 public immutable maxBuybackPerBatch;
    uint32 public immutable minBuybackInterval;
    uint256 public immutable maxLiquidityPerBatch;
    uint16 public immutable maxSlippageBps;
    int24 public immutable maxTickDeviation;
    uint16 public immutable maxOpsShareBps;
    uint256 public immutable maxOpsPerWindow;
    uint32 public immutable opsWindow;
    uint32 public immutable minHoneyEpoch;
    uint32 public immutable maxHoneyEpoch;

    // wiring (set once by the deployer in `initialize`)
    IHiveTokenT public token;
    IHiveHookT public hook;
    IHiveResidentsT public residents;
    IHiveObserverT public observer;
    PoolKey internal _key;
    bool public initialized;

    // roles
    address public admin;
    address public pendingAdmin;
    address public executor;
    bool public executorFrozen;

    // budgets (wei)
    uint256 public lpBudget;
    uint256 public burnBudget;
    uint256 public honeyBudget;
    uint256 public opsBudget;
    uint256 public reserveBudget;
    Allocation public allocation;
    mapping(bytes32 => bool) public jobDone;

    // positions and history
    int24 public launchTickLower;
    int24 public launchTickUpper;
    uint128 public launchLiquidity;
    uint128 public growthLiquidity;
    uint64 public lastBuybackAt;
    uint64 public opsWindowStart;
    uint256 public opsSpentInWindow;

    uint256 public totalProjectFeeIncome;
    uint256 public totalLpFeeIncomeEth;
    uint256 public totalLpFeeIncomeHive;
    uint256 public totalOtherIncome;
    uint256 public totalBoughtBack;
    uint256 public totalBurned;
    uint256 public totalLiquidityEth;
    uint256 public totalLiquidityHive;
    uint256 public totalHoneyFunded;
    uint256 public totalOpsPaid;

    event Initialized(PoolId indexed poolId, uint160 sqrtPriceX96, uint128 launchLiquidity, uint256 hiveSeeded);
    event ExecutorSet(address indexed executor);
    event ExecutorFrozen(bool frozen);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferred(address indexed admin);
    event IncomeAllocated(uint256 projectFees, uint256 lpFees, uint256 other, Allocation allocation);
    event AllocationSet(bytes32 indexed jobId, Allocation allocation);
    event BuybackExecuted(bytes32 indexed jobId, Budget source, uint256 ethIn, uint256 hiveOut, bool burned);
    event HiveBurned(bytes32 indexed jobId, uint256 amount);
    event LiquidityAdded(bytes32 indexed jobId, uint256 ethUsed, uint256 hiveUsed, uint128 liquidity);
    event LpFeesCollected(uint256 eth, uint256 hive);
    event HoneyFunded(bytes32 indexed jobId, uint256 amount, uint32 duration);
    event OpsPaid(bytes32 indexed jobId, address indexed to, uint256 amount);
    event ReserveReleased(bytes32 indexed jobId, Budget to, uint256 amount);
    event LaunchBuy(address indexed to, uint256 ethIn, uint256 hiveOut);

    error NotDeployer();
    error AlreadyInitialized();
    error NotInitialized();
    error NotAdmin();
    error NotExecutor();
    error JobDone(bytes32 jobId);
    error Expired();
    error BadWiring(uint8 code);
    error BadAllocation();
    error OverBudget(Budget budget, uint256 requested, uint256 available);
    error BatchTooLarge();
    error TooSoon();
    error TwapUnavailable();
    error MinOutTooLow(uint256 minOut, uint256 required);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error PriceDeviation(int24 spot, int24 twap);
    error BadEpoch();
    error OpsLimit();
    error NotPoolManager();
    error BadBudget();
    error TransferFailed();
    error LaunchBuyTooLarge(uint256 hiveOut, uint256 max);

    modifier onlyExecutor(bytes32 jobId) {
        if (msg.sender != executor || executorFrozen || executor == address(0)) revert NotExecutor();
        if (!initialized) revert NotInitialized();
        if (jobId == bytes32(0) || jobDone[jobId]) revert JobDone(jobId);
        jobDone[jobId] = true;
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        address admin_,
        address executor_,
        address opsRecipient_,
        Allocation memory allocation_,
        Limits memory l
    ) {
        if (address(poolManager_) == address(0) || admin_ == address(0) || opsRecipient_ == address(0)) {
            revert BadWiring(0);
        }
        if (l.maxOpsShareBps > 3000 || l.maxSlippageBps > 2000 || l.minHoneyEpoch == 0 || l.maxHoneyEpoch < l.minHoneyEpoch) {
            revert BadWiring(1);
        }
        poolManager = poolManager_;
        deployer = msg.sender;
        admin = admin_;
        executor = executor_;
        opsRecipient = opsRecipient_;
        maxBuybackPerBatch = l.maxBuybackPerBatch;
        minBuybackInterval = l.minBuybackInterval;
        maxLiquidityPerBatch = l.maxLiquidityPerBatch;
        maxSlippageBps = l.maxSlippageBps;
        maxTickDeviation = l.maxTickDeviation;
        maxOpsShareBps = l.maxOpsShareBps;
        maxOpsPerWindow = l.maxOpsPerWindow;
        opsWindow = l.opsWindow;
        minHoneyEpoch = l.minHoneyEpoch;
        maxHoneyEpoch = l.maxHoneyEpoch;
        _checkAllocation(allocation_);
        allocation = allocation_;
    }

    receive() external payable {}

    // ============================================================================================ launch

    /// @notice One-time wiring by the deploying graph: binds token, hook and residents, initializes the canonical
    ///         pool at `sqrtPriceX96` and seeds `seedAmount` HIVE as a single-sided, permanently locked position below
    ///         the start price. Any HIVE not seeded stays in the treasury reserve. ETH sent with this call is the
    ///         launch buy: it buys HIVE in the same transaction, before anyone else can trade, for the executor (the
    ///         dev wallet the council works from), capped at MAX_LAUNCH_BUY_BPS of the launch supply.
    function initialize(
        address token_,
        address hook_,
        address residents_,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 seedAmount
    ) external payable {
        if (msg.sender != deployer) revert NotDeployer();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        token = IHiveTokenT(token_);
        hook = IHiveHookT(hook_);
        residents = IHiveResidentsT(residents_);
        observer = IHiveObserverT(hook.observer());
        if (hook.token() != token_ || hook.treasury() != address(this)) revert BadWiring(2);
        if (residents.token() != token_ || residents.treasury() != address(this)) revert BadWiring(3);
        if (token.balanceOf(address(this)) != token.LAUNCH_SUPPLY() || seedAmount > token.LAUNCH_SUPPLY()) {
            revert BadWiring(4);
        }
        if (uint160(token_) == 0) revert BadWiring(5);
        int24 spacing = hook.tickSpacing();
        _key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token_),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(hook_)
        });
        int24 startTick = poolManager.initialize(_key, sqrtPriceX96);
        if (tickUpper > startTick || tickLower >= tickUpper || tickLower % spacing != 0 || tickUpper % spacing != 0) {
            revert BadWiring(6);
        }
        launchTickLower = tickLower;
        launchTickUpper = tickUpper;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), seedAmount
        );
        launchLiquidity = liquidity;
        poolManager.unlock(abi.encode(Op.Seed, abi.encode(tickLower, tickUpper, liquidity)));
        emit Initialized(_key.toId(), sqrtPriceX96, liquidity, seedAmount);
        if (msg.value != 0) _launchBuy();
    }

    function _launchBuy() internal {
        if (executor == address(0)) revert BadWiring(7);
        uint256 out = _buy(msg.value);
        uint256 max = token.LAUNCH_SUPPLY() * MAX_LAUNCH_BUY_BPS / BPS;
        if (out > max) revert LaunchBuyTooLarge(out, max);
        if (!token.transfer(executor, out)) revert TransferFailed();
        emit LaunchBuy(executor, msg.value, out);
    }

    // ============================================================================================ income

    /// @notice Pulls project fees from the hook and allocates every unaccounted wei by the current allocation.
    function sync() public returns (uint256 allocated) {
        if (!initialized) revert NotInitialized();
        uint256 swept = hook.sweepProjectFees();
        totalProjectFeeIncome += swept;
        allocated = _allocateUnaccounted(swept, 0);
    }

    /// @notice Collects LP fees accrued by the treasury's own positions (permissionless). ETH is allocated like other
    ///         income; HIVE joins the treasury's HIVE reserve.
    function collectLpFees() public returns (uint256 eth, uint256 hive) {
        if (!initialized) revert NotInitialized();
        sync();
        if (launchLiquidity == 0 && growthLiquidity == 0) return (0, 0);
        bytes memory res = poolManager.unlock(abi.encode(Op.Collect, ""));
        (eth, hive) = abi.decode(res, (uint256, uint256));
        totalLpFeeIncomeEth += eth;
        totalLpFeeIncomeHive += hive;
        _allocateUnaccounted(0, eth);
        emit LpFeesCollected(eth, hive);
    }

    function _allocateUnaccounted(uint256 projectPart, uint256 lpPart) internal returns (uint256 income) {
        uint256 budgets = totalBudgets();
        uint256 bal = address(this).balance;
        if (bal <= budgets) return 0;
        income = bal - budgets;
        Allocation memory a = allocation;
        uint256 toLp = income * a.lp / BPS;
        uint256 toBurn = income * a.burn / BPS;
        uint256 toHoney = income * a.honey / BPS;
        uint256 toOps = income * a.ops / BPS;
        lpBudget += toLp;
        burnBudget += toBurn;
        honeyBudget += toHoney;
        opsBudget += toOps;
        reserveBudget += income - toLp - toBurn - toHoney - toOps; // rounding dust lands in the reserve
        uint256 other = income > projectPart + lpPart ? income - projectPart - lpPart : 0;
        totalOtherIncome += other;
        emit IncomeAllocated(projectPart, lpPart, other, a);
    }

    function totalBudgets() public view returns (uint256) {
        return lpBudget + burnBudget + honeyBudget + opsBudget + reserveBudget;
    }

    // ============================================================================================ council actions

    /// @notice Sets the split for future inflows. Everything already accrued is allocated under the old split first.
    function setAllocation(bytes32 jobId, Allocation calldata a) external onlyExecutor(jobId) {
        sync();
        _checkAllocation(a);
        allocation = a;
        emit AllocationSet(jobId, a);
    }

    /// @notice Buys HIVE with ETH from the burn or reserve budget through the canonical pool and burns or holds it.
    function buyback(bytes32 jobId, Budget source, uint256 ethIn, uint256 minHiveOut, bool burnIt, uint64 deadline)
        external
        onlyExecutor(jobId)
        returns (uint256 hiveOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (source != Budget.Burn && source != Budget.Reserve) revert BadBudget();
        if (ethIn == 0 || ethIn > maxBuybackPerBatch) revert BatchTooLarge();
        if (block.timestamp < uint256(lastBuybackAt) + minBuybackInterval) revert TooSoon();
        sync();
        _spend(source, ethIn);
        _requireFairMinOut(ethIn, minHiveOut);
        lastBuybackAt = uint64(block.timestamp);
        hiveOut = _buy(ethIn);
        if (hiveOut < minHiveOut) revert InsufficientOutput(hiveOut, minHiveOut);
        totalBoughtBack += hiveOut;
        if (burnIt) {
            token.burn(hiveOut);
            totalBurned += hiveOut;
        }
        emit BuybackExecuted(jobId, source, ethIn, hiveOut, burnIt);
    }

    /// @notice Burns HIVE held in the treasury reserve.
    function burnReserveHive(bytes32 jobId, uint256 amount) external onlyExecutor(jobId) {
        token.burn(amount);
        totalBurned += amount;
        emit HiveBurned(jobId, amount);
    }

    /// @notice Grows the treasury-owned full-range position: optionally buys HIVE with part of the batch, then adds
    ///         ETH + HIVE (bought and/or from the HIVE reserve). Unused ETH returns to the LP budget.
    function growLiquidity(
        bytes32 jobId,
        uint256 ethTotal,
        uint256 ethForHive,
        uint256 minHiveOut,
        uint256 hiveFromReserve,
        uint64 deadline
    ) external onlyExecutor(jobId) returns (uint128 liquidity) {
        if (block.timestamp > deadline) revert Expired();
        if (ethTotal == 0 || ethTotal > maxLiquidityPerBatch || ethForHive > ethTotal) revert BatchTooLarge();
        collectLpFees(); // fees of the existing position are income, not netted into this batch
        _spend(Budget.Lp, ethTotal);
        _requireSpotNearTwap();
        uint256 hiveAvail = hiveFromReserve;
        if (ethForHive != 0) {
            _requireFairMinOut(ethForHive, minHiveOut);
            uint256 got = _buy(ethForHive);
            if (got < minHiveOut) revert InsufficientOutput(got, minHiveOut);
            hiveAvail += got;
        }
        uint256 ethAvail = ethTotal - ethForHive;
        if (token.balanceOf(address(this)) < hiveAvail) revert OverBudget(Budget.Reserve, hiveAvail, token.balanceOf(address(this)));
        (uint160 sqrtP,,,) = poolManager.getSlot0(_key.toId());
        int24 spacing = _key.tickSpacing;
        (int24 lo, int24 hi) = (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), ethAvail, hiveAvail
        );
        uint256 balBefore = address(this).balance;
        bytes memory res = poolManager.unlock(abi.encode(Op.AddLiquidity, abi.encode(lo, hi, liquidity, GROWTH_SALT)));
        (uint256 ethUsed, uint256 hiveUsed) = abi.decode(res, (uint256, uint256));
        // Unused ETH of the batch goes back to the LP budget.
        uint256 ethSpentNow = balBefore - address(this).balance;
        if (ethSpentNow < ethAvail) lpBudget += ethAvail - ethSpentNow;
        growthLiquidity += liquidity;
        totalLiquidityEth += ethUsed;
        totalLiquidityHive += hiveUsed;
        emit LiquidityAdded(jobId, ethUsed, hiveUsed, liquidity);
    }

    /// @notice Sends honey-budget ETH to the resident vault as a funding epoch.
    function fundHoney(bytes32 jobId, uint256 amount, uint32 duration) external onlyExecutor(jobId) {
        if (duration < minHoneyEpoch || duration > maxHoneyEpoch) revert BadEpoch();
        sync();
        _spend(Budget.Honey, amount);
        totalHoneyFunded += amount;
        residents.fund{value: amount}(duration);
        emit HoneyFunded(jobId, amount, duration);
    }

    /// @notice Pays operations budget (agent API and gas costs) to the immutable ops recipient, rate-limited.
    function payOps(bytes32 jobId, uint256 amount) external onlyExecutor(jobId) {
        sync();
        if (block.timestamp >= uint256(opsWindowStart) + opsWindow) {
            opsWindowStart = uint64(block.timestamp);
            opsSpentInWindow = 0;
        }
        if (opsSpentInWindow + amount > maxOpsPerWindow) revert OpsLimit();
        opsSpentInWindow += amount;
        _spend(Budget.Ops, amount);
        totalOpsPaid += amount;
        (bool ok,) = opsRecipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit OpsPaid(jobId, opsRecipient, amount);
    }

    /// @notice Commits uncommitted reserve ETH to the LP, burn or honey budget. Other budgets cannot be repurposed.
    function releaseReserve(bytes32 jobId, Budget to, uint256 amount) external onlyExecutor(jobId) {
        if (to != Budget.Lp && to != Budget.Burn && to != Budget.Honey) revert BadBudget();
        sync();
        _spend(Budget.Reserve, amount);
        if (to == Budget.Lp) lpBudget += amount;
        else if (to == Budget.Burn) burnBudget += amount;
        else honeyBudget += amount;
        emit ReserveReleased(jobId, to, amount);
    }

    // ============================================================================================ admin

    function setExecutor(address e) external onlyAdmin {
        executor = e;
        emit ExecutorSet(e);
    }

    function setExecutorFrozen(bool frozen) external onlyAdmin {
        executorFrozen = frozen;
        emit ExecutorFrozen(frozen);
    }

    function transferAdmin(address a) external onlyAdmin {
        pendingAdmin = a;
        emit AdminTransferStarted(a);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(msg.sender);
    }

    // ============================================================================================ views

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function hiveReserve() external view returns (uint256) {
        return initialized ? token.balanceOf(address(this)) : 0;
    }

    // ============================================================================================ v4 plumbing

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        if (op == Op.Seed) {
            (int24 lo, int24 hi, uint128 liq) = abi.decode(args, (int24, int24, uint128));
            (uint256 e, uint256 h) = _modify(lo, hi, int256(uint256(liq)), LAUNCH_SALT);
            return abi.encode(e, h);
        }
        if (op == Op.AddLiquidity) {
            (int24 lo, int24 hi, uint128 liq, bytes32 salt) = abi.decode(args, (int24, int24, uint128, bytes32));
            (uint256 e, uint256 h) = _modify(lo, hi, int256(uint256(liq)), salt);
            return abi.encode(e, h);
        }
        if (op == Op.Buy) {
            uint256 ethIn = abi.decode(args, (uint256));
            BalanceDelta d = poolManager.swap(
                _key, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
            );
            uint256 owed = uint256(int256(-d.amount0()));
            uint256 out = uint256(int256(d.amount1()));
            poolManager.settle{value: owed}();
            poolManager.take(_key.currency1, address(this), out);
            return abi.encode(out);
        }
        // Collect: poke both positions with zero liquidity delta; accrued fees come back as positive deltas.
        uint256 ethFees;
        uint256 hiveFees;
        if (launchLiquidity != 0) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                _key, ModifyLiquidityParams(launchTickLower, launchTickUpper, 0, LAUNCH_SALT), ""
            );
            ethFees += uint256(int256(d.amount0()));
            hiveFees += uint256(int256(d.amount1()));
        }
        if (growthLiquidity != 0) {
            int24 spacing = _key.tickSpacing;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                _key,
                ModifyLiquidityParams(TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing), 0, GROWTH_SALT),
                ""
            );
            ethFees += uint256(int256(d.amount0()));
            hiveFees += uint256(int256(d.amount1()));
        }
        if (ethFees != 0) poolManager.take(_key.currency0, address(this), ethFees);
        if (hiveFees != 0) poolManager.take(_key.currency1, address(this), hiveFees);
        return abi.encode(ethFees, hiveFees);
    }

    /// @dev Adds liquidity and settles what is owed. Positive deltas (fees of an existing position) are taken.
    function _modify(int24 lo, int24 hi, int256 liq, bytes32 salt) internal returns (uint256 ethPaid, uint256 hivePaid) {
        (BalanceDelta d,) = poolManager.modifyLiquidity(_key, ModifyLiquidityParams(lo, hi, liq, salt), "");
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 < 0) {
            ethPaid = uint256(int256(-a0));
            poolManager.settle{value: ethPaid}();
        } else if (a0 > 0) {
            poolManager.take(_key.currency0, address(this), uint256(int256(a0)));
        }
        if (a1 < 0) {
            hivePaid = uint256(int256(-a1));
            poolManager.sync(_key.currency1);
            if (!token.transfer(address(poolManager), hivePaid)) revert TransferFailed();
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(_key.currency1, address(this), uint256(int256(a1)));
        }
    }

    function _buy(uint256 ethIn) internal returns (uint256 out) {
        bytes memory res = poolManager.unlock(abi.encode(Op.Buy, abi.encode(ethIn)));
        out = abi.decode(res, (uint256));
    }

    function _spend(Budget b, uint256 amount) internal {
        uint256 avail;
        if (b == Budget.Lp) avail = lpBudget;
        else if (b == Budget.Burn) avail = burnBudget;
        else if (b == Budget.Honey) avail = honeyBudget;
        else if (b == Budget.Ops) avail = opsBudget;
        else avail = reserveBudget;
        if (amount > avail) revert OverBudget(b, amount, avail);
        if (b == Budget.Lp) lpBudget = avail - amount;
        else if (b == Budget.Burn) burnBudget = avail - amount;
        else if (b == Budget.Honey) honeyBudget = avail - amount;
        else if (b == Budget.Ops) opsBudget = avail - amount;
        else reserveBudget = avail - amount;
    }

    /// @dev minOut must be at least (1 - maxSlippage) of the HIVE the TWAP price implies after platform and LP fees.
    function _requireFairMinOut(uint256 ethIn, uint256 minOut) internal view {
        (bool ok, int24 avgTick,) = observer.twapTick(observer.twapWindow());
        if (!ok) revert TwapUnavailable();
        (Policy memory p,,) = hook.effectivePolicy();
        uint256 net = ethIn * (PIPS - hook.platformFeePips() - p.lpFee) / PIPS;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(avgTick);
        uint256 implied = FullMath.mulDiv(FullMath.mulDiv(net, sqrtP, 1 << 96), sqrtP, 1 << 96);
        uint256 required = implied * (BPS - maxSlippageBps) / BPS;
        if (minOut < required || minOut == 0) revert MinOutTooLow(minOut, required);
    }

    function _requireSpotNearTwap() internal view {
        (bool ok, int24 avgTick,) = observer.twapTick(observer.twapWindow());
        if (!ok) revert TwapUnavailable();
        (, int24 spot,,) = poolManager.getSlot0(_key.toId());
        int24 diff = spot > avgTick ? spot - avgTick : avgTick - spot;
        if (diff > maxTickDeviation) revert PriceDeviation(spot, avgTick);
    }

    function _checkAllocation(Allocation memory a) internal view {
        if (uint256(a.lp) + a.burn + a.honey + a.ops + a.reserve != BPS) revert BadAllocation();
        if (a.ops > maxOpsShareBps) revert BadAllocation();
    }
}
