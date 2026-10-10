// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {OracleConfig, Policy, Tier, Guard, Constitution} from "./HiveTypes.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

interface IHiveHookObs {
    function token() external view returns (address);
    function quoteIsCurrency0() external view returns (bool);
    function observer() external view returns (address);
    function cumulativeTick() external view returns (int64 cumulative, uint32 timestamp);
    function poolInitialized() external view returns (bool);
    function constitution() external view returns (Constitution memory);
    function buyFloorAmount() external view returns (uint256);
    function sellFloorAmount() external view returns (uint256);
    function baselinePolicy() external view returns (Policy memory);
}

/// @title HiveObserver
/// @notice Permissionless market observation and the hook's policy rules. It reads; it never changes a trading rule.
///         Supply-based market cap = time-weighted HIVE price (from the hook's cumulative tick, over at least
///         `twapWindow`, at most `maxTwapSpan`) x quote/USD feed answer (fresh within `maxFeedAge`) x totalSupply.
///         This is labelled a supply-based market cap; it is not an independently verified circulating market cap.
contract HiveObserver {
    uint8 internal constant CHECKPOINTS = 12;

    address public immutable deployer;
    address public immutable quoteUsdFeed;
    uint32 public immutable twapWindow;
    uint32 public immutable maxTwapSpan;
    uint32 public immutable checkpointSpacing;
    uint32 public immutable maxFeedAge;

    IHiveHookObs public hook;
    address public token;
    bool public quoteIsCurrency0;

    struct Checkpoint {
        uint32 ts;
        int64 cumulative;
    }

    Checkpoint[12] internal _checkpoints;
    uint8 internal _head;
    uint8 internal _count;

    uint64 public lastObservationAt;
    uint256 public lastMarketCapUsd8;
    bool public lastObservationValid;

    event Observed(bool valid, uint256 marketCapUsd8);

    error NotDeployer();
    error AlreadyInitialized();
    error BadConfig();

    constructor(OracleConfig memory o) {
        if (
            o.twapWindow == 0 || o.maxTwapSpan < o.twapWindow || o.checkpointSpacing == 0
                || uint256(o.checkpointSpacing) * CHECKPOINTS < uint256(o.twapWindow) + o.checkpointSpacing
                || o.maxFeedAge == 0
        ) revert BadConfig();
        deployer = msg.sender;
        quoteUsdFeed = o.quoteUsdFeed;
        twapWindow = o.twapWindow;
        maxTwapSpan = o.maxTwapSpan;
        checkpointSpacing = o.checkpointSpacing;
        maxFeedAge = o.maxFeedAge;
    }

    /// @notice One-time binding to the hook (the hook embeds this observer's address immutably).
    function initialize(address hook_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(hook) != address(0)) revert AlreadyInitialized();
        if (IHiveHookObs(hook_).observer() != address(this)) revert BadConfig();
        hook = IHiveHookObs(hook_);
        token = IHiveHookObs(hook_).token();
        quoteIsCurrency0 = IHiveHookObs(hook_).quoteIsCurrency0();
        // the hook's baseline must satisfy the constitution like every later policy
        _validate(IHiveHookObs(hook_).baselinePolicy());
    }

    // ============================================================================================ policy rules

    uint8 internal constant MAX_TIERS = 3;
    uint16 internal constant MIN_GUARD_TICKS = 500; // ≈ 5 %, mirrors HiveHook.MIN_GUARD_TICKS (storm threshold)
    uint256 internal constant PIPS = 1_000_000;

    error InvalidPolicy(uint8 code);

    /// @notice The hook's policy rules (kept here so the hook stays under the contract size limit): reverts with
    ///         InvalidPolicy(code) unless `m` satisfies the hook's constitution, and reports whether `m` is nowhere
    ///         stricter for traders than `e` and, when `e` expires, than `base`. A pure function of its inputs and the
    ///         hook's immutable constitution.
    function checkPolicy(Policy calldata m, Policy calldata e, Policy calldata base, bool eExpires)
        external
        view
        returns (bool relaxing)
    {
        _validate(m);
        relaxing = _noStricter(m, e) && (!eExpires || _noStricter(m, base));
    }

    /// @dev Codes: 1 buy cap zero, 2 buy cap below the permanent buy floor, 3 sell cap below floor, 4 LP fee out of
    ///      range, 5 tier count, 6 tier order, 7 all-in ceiling exceeded, 8 fee > 100%, 9 storm threshold below
    ///      MIN_GUARD_TICKS, 11 reference window, 12 storm threshold and fee not set together, 13 surcharge above the
    ///      all-in ceiling. (Code 10 is unused: there is no trading halt to configure.)
    function _validate(Policy memory p) internal view {
        Constitution memory c = hook.constitution();
        if (p.buyCapOn) {
            if (p.buyCap == 0) revert InvalidPolicy(1);
            if (p.buyCap < hook.buyFloorAmount()) revert InvalidPolicy(2);
        }
        if (p.sellCapOn && p.sellCap < hook.sellFloorAmount()) revert InvalidPolicy(3);
        if (p.lpFee < c.minLpFeePips || p.lpFee > c.maxLpFeePips) revert InvalidPolicy(4);
        if (p.tierCount > MAX_TIERS) revert InvalidPolicy(5);
        uint256 fixedPart = uint256(c.platformFeePips) + p.lpFee;
        if (p.buyFee >= PIPS || p.sellFee >= PIPS) revert InvalidPolicy(8);
        if (fixedPart + p.buyFee > c.maxAllInPips || fixedPart + p.sellFee > c.maxAllInPips) revert InvalidPolicy(7);
        uint96 prev;
        for (uint8 i; i < p.tierCount; ++i) {
            Tier memory t = p.tiers[i];
            if (t.minQuote == 0 || t.minQuote <= prev) revert InvalidPolicy(6);
            prev = t.minQuote;
            if (fixedPart + t.buyFee > c.maxAllInPips || fixedPart + t.sellFee > c.maxAllInPips) revert InvalidPolicy(7);
        }
        for (uint8 i = p.tierCount; i < MAX_TIERS; ++i) {
            Tier memory t = p.tiers[i];
            if (t.minQuote != 0 || t.buyFee != 0 || t.sellFee != 0) revert InvalidPolicy(5);
        }
        Guard memory g = p.guard;
        if (g.stormDropTicks != 0 && g.stormDropTicks < MIN_GUARD_TICKS) revert InvalidPolicy(9);
        if (g.stormDropTicks != 0 ? (g.refWindow < 60 || g.refWindow > 1 days) : g.refWindow != 0) revert InvalidPolicy(11);
        if ((g.stormDropTicks == 0) != (g.stormFee == 0)) revert InvalidPolicy(12);
        if (g.stormFee > c.maxAllInPips || g.botFee > c.maxAllInPips) revert InvalidPolicy(13);
    }

    /// @dev True if `a` is nowhere stricter for traders than `b`: caps at least as large (or absent), LP fee and every
    ///      point of both fee schedules no higher, no exact-output restriction added, and no guard more sensitive or
    ///      more expensive (a changed reference window while the storm fee is on counts as stricter).
    function _noStricter(Policy memory a, Policy memory b) internal pure returns (bool) {
        if (a.buyCapOn && (!b.buyCapOn || a.buyCap < b.buyCap)) return false;
        if (a.sellCapOn && (!b.sellCapOn || a.sellCap < b.sellCap)) return false;
        if (a.lpFee > b.lpFee) return false;
        if (a.tierCount != 0 && b.tierCount == 0) return false;
        // Fee schedules are step functions; compare at 0 and at every threshold of either policy.
        if (!_scheduleNoHigher(a, b, 0)) return false;
        for (uint8 i; i < a.tierCount; ++i) {
            if (!_scheduleNoHigher(a, b, a.tiers[i].minQuote)) return false;
        }
        for (uint8 i; i < b.tierCount; ++i) {
            if (!_scheduleNoHigher(a, b, b.tiers[i].minQuote)) return false;
        }
        Guard memory ga = a.guard;
        Guard memory gb = b.guard;
        if (_tighter(ga.stormDropTicks, gb.stormDropTicks)) return false;
        if (ga.stormFee > gb.stormFee || ga.botFee > gb.botFee) return false;
        if (ga.refWindow != gb.refWindow && ga.refWindow != 0) return false;
        return true;
    }

    function _scheduleNoHigher(Policy memory a, Policy memory b, uint256 q) internal pure returns (bool) {
        (uint256 aBuy, uint256 aSell) = _feesAt(a, q);
        (uint256 bBuy, uint256 bSell) = _feesAt(b, q);
        return aBuy <= bBuy && aSell <= bSell;
    }

    function _feesAt(Policy memory p, uint256 q) internal pure returns (uint256 buy, uint256 sell) {
        buy = p.buyFee;
        sell = p.sellFee;
        for (uint8 i; i < p.tierCount; ++i) {
            if (q < p.tiers[i].minQuote) break;
            buy = p.tiers[i].buyFee;
            sell = p.tiers[i].sellFee;
        }
    }

    /// @dev threshold `a` reacts to a smaller move than `b` (zero = off)
    function _tighter(uint16 a, uint16 b) internal pure returns (bool) {
        return a != 0 && (b == 0 || a < b);
    }

    /// @notice Stores a cumulative-tick checkpoint, at most one per `checkpointSpacing`. Permissionless.
    function checkpoint() public {
        if (!hook.poolInitialized()) return;
        if (_count != 0 && block.timestamp < uint256(_checkpoints[_head].ts) + checkpointSpacing) return;
        (int64 cum, uint32 ts) = hook.cumulativeTick();
        uint8 next = _count == 0 ? 0 : (_head + 1) % CHECKPOINTS;
        _checkpoints[next] = Checkpoint(ts, cum);
        _head = next;
        if (_count < CHECKPOINTS) _count++;
    }

    /// @notice Checkpoints and records a market-cap reading. Permissionless; it changes no trading rule.
    function observe() external returns (bool valid, uint256 marketCapUsd8) {
        checkpoint();
        (valid, marketCapUsd8) = measureMarketCap();
        lastObservationAt = uint64(block.timestamp);
        lastObservationValid = valid;
        lastMarketCapUsd8 = valid ? marketCapUsd8 : 0;
        emit Observed(valid, marketCapUsd8);
    }

    /// @notice Time-weighted average tick over the newest checkpoint that is at least `minAge` old.
    function twapTick(uint32 minAge) public view returns (bool ok, int24 avgTick, uint32 span) {
        if (address(hook) == address(0) || minAge == 0 || !hook.poolInitialized()) return (false, 0, 0);
        (int64 cumNow,) = hook.cumulativeTick();
        for (uint8 i; i < _count; ++i) {
            Checkpoint memory c = _checkpoints[(_head + CHECKPOINTS - i) % CHECKPOINTS];
            if (block.timestamp >= uint256(c.ts) + minAge) {
                span = uint32(block.timestamp - c.ts);
                if (span > maxTwapSpan) return (false, 0, span);
                int64 diff = cumNow - c.cumulative;
                int64 avg = diff / int64(uint64(span));
                if (diff < 0 && diff % int64(uint64(span)) != 0) avg--;
                return (true, int24(avg), span);
            }
        }
        return (false, 0, 0);
    }

    /// @notice Supply-based market cap in USD with 8 decimals, or (false, 0) when any input is unavailable/stale.
    function measureMarketCap() public view returns (bool, uint256) {
        if (quoteUsdFeed == address(0)) return (false, 0);
        (bool ok, int24 avgTick,) = twapTick(twapWindow);
        if (!ok) return (false, 0);
        uint256 usd8;
        try IAggregatorV3(quoteUsdFeed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0);
            if (block.timestamp - updatedAt > maxFeedAge) return (false, 0);
            uint8 dec;
            try IAggregatorV3(quoteUsdFeed).decimals() returns (uint8 d) {
                dec = d;
            } catch {
                return (false, 0);
            }
            if (dec > 30) return (false, 0);
            // forge-lint: disable-next-line(unsafe-typecast)
            usd8 = dec >= 8 ? uint256(answer) / 10 ** (dec - 8) : uint256(answer) * 10 ** (8 - dec);
        } catch {
            return (false, 0);
        }
        (bool sok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!sok || data.length < 32) return (false, 0);
        uint256 supply = abi.decode(data, (uint256));
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(avgTick);
        // Both assets have 18 decimals. HIVE price in quote = 1/p if quote is currency0, else p; p = sqrtP^2 / 2^192.
        uint256 quoteValue = quoteIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(supply, 1 << 96, sqrtP), 1 << 96, sqrtP)
            : FullMath.mulDiv(FullMath.mulDiv(supply, sqrtP, 1 << 96), sqrtP, 1 << 96);
        return (true, FullMath.mulDiv(quoteValue, usd8, 1e18));
    }

    function checkpointCount() external view returns (uint8) {
        return _count;
    }
}
