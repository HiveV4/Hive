// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice One size-sensitive project-fee tier. At or above `minQuote` (gross quote-currency amount of the swap, wei),
///         `buyFee` / `sellFee` replace the base project fee for that direction. Units: pips (1_000_000 = 100%).
struct Tier {
    uint96 minQuote;
    uint24 buyFee;
    uint24 sellFee;
}

/// @notice A complete trading policy for the canonical pool. Caps are per-swap HIVE amounts (wei). An absent cap is
///         expressed by `buyCapOn == false` / `sellCapOn == false` and means unlimited; a zero cap value is never
///         interpreted as "unlimited" and is rejected by validation.
struct Policy {
    bool buyCapOn;
    bool sellCapOn;
    uint128 buyCap;
    uint128 sellCap;
    uint24 buyFee; // project fee on buys, pips of gross quote amount
    uint24 sellFee; // project fee on sells, pips of gross quote amount
    uint24 lpFee; // dynamic LP fee returned as override on every swap, pips
    uint8 tierCount;
    Tier[3] tiers;
    Guard guard;
}

/// @notice Market guards. Prices are compared in ticks of the HIVE price (1 tick ≈ 0.01 %) against a reference price
///         that is renewed at the first swap after `refWindow` seconds. A zero threshold or fee switches a guard off.
///         Surcharges (storm, bot) are project fees: they go to the treasury and follow the council's allocation; the
///         sum of all fees on a swap is clamped to the constitution's all-in ceiling.
struct Guard {
    uint16 brakeDropTicks; // emergency brake: HIVE this far below the reference halts buys and sells
    uint16 brakeRiseTicks; // emergency brake: HIVE this far above the reference halts buys and sells
    uint32 brakeHalt; // length of a halt in seconds (<= constitution maxHalt)
    uint32 refWindow; // reference price lifetime in seconds (required while the brake or the storm fee is on)
    uint16 stormDropTicks; // storm: HIVE this far below the reference makes sells pay `stormFee` on top
    uint24 stormFee; // extra sell fee during a storm, pips
    uint24 botFee; // bot shield: extra fee on the second leg of a buy+sell by one tx.origin in one block, pips
}

/// @notice Hard limits fixed at deployment. Nothing — admin, controller or council — can change them afterwards.
struct Constitution {
    uint24 platformFeePips; // Programmable platform fee, pips of gross quote amount, every buy and sell
    uint24 maxAllInPips; // ceiling for platform + project (any tier) + LP fee, additive (upper bound of compounded)
    uint24 minLpFeePips;
    uint24 maxLpFeePips;
    uint16 earlyBuyCapFloorBps; // while the early floor is active an enabled buy cap is never below this share of launch supply
    uint16 sellCapFloorBps; // an enabled sell cap is never below this share of launch supply
    uint32 activationDelay; // minimum notice for any change that is stricter for traders
    uint32 maxHalt; // longest trading halt the emergency brake may impose
    uint32 haltCooldown; // minimum gap between the end of one halt and the next trip of the brake
}

/// @notice Configuration of the supply-based market-cap observation that can release the early buy-cap floor.
struct OracleConfig {
    address quoteUsdFeed; // Chainlink-style aggregator for quote/USD; address(0) keeps the floor permanently active
    uint128 thresholdUsd8; // supply-based market cap threshold, 8 decimals
    uint32 twapWindow; // minimum TWAP span
    uint32 maxTwapSpan; // a TWAP over a longer span is treated as unavailable
    uint32 checkpointSpacing; // minimum spacing between stored cumulative-tick checkpoints
    uint32 sustainPeriod; // threshold must hold across consecutive observations for this long before release
    uint32 maxObservationGap; // a longer gap between observations restarts the sustain clock
    uint32 unlockValidity; // a release lapses automatically this long after the last confirming observation
    uint32 maxFeedAge; // older feed answers are stale
}
