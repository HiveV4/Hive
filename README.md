# HIVE — contracts

HIVE is a colony on Ethereum built around a single Uniswap v4 pool. A council of three characters (Mason, Ember and
Nectar) debates the colony's market and changes its trading rules over time — but only inside limits that are fixed in
these contracts and cannot be changed by anyone.

This repository contains the exact on-chain source of the colony, as compiled for the launch.

## Contracts

| Contract | What it does |
| --- | --- |
| [`HiveToken`](src/HiveToken.sol) | Fixed-supply ERC-20 ($HIVE, 1,000,000,000). Minted once to the treasury. No owner, no mint, no tax, no blocklist, no pause. Anyone can burn their own tokens. Presentation metadata via `metadata()` and `tokenURI()` (inline JSON with description, image, website and X profile), fixed at deployment. |
| [`HiveHook`](src/HiveHook.sol) | Uniswap v4 hook of the canonical HIVE/ETH pool. Enforces the current trading policy: buy/sell size caps, project fees, dynamic LP fee, the platform fee, and the market guards (emergency brake, storm fee, bot shield, honey hours). Rules that are stricter for traders take effect only after a public notice period, and every temporary rule expires on its own. |
| [`HiveObserver`](src/HiveObserver.sol) | Permissionless market observation (TWAP × ETH/USD feed) for the early buy-cap floor, and validation of every policy against the hard limits. |
| [`HiveResidents`](src/HiveResidents.sol) | Resident vault. Deposit HIVE to become a resident; `leave` always returns exactly what was deposited. Residents share ETH "honey" streamed by the treasury. |
| [`HiveTreasury`](src/HiveTreasury.sol) | The colony pantry. Initializes and seeds the pool (liquidity is permanently locked — there is no function that removes it), splits income into budgets and spends only through bounded actions: buybacks, burns, liquidity growth, honey, and rate-limited operations payouts. |

### Launch buy

ETH sent with the launch transaction buys HIVE in that same transaction, before anyone else can trade, for the
colony's executor wallet. It is capped in code at 5% of the launch supply (`HiveTreasury.MAX_LAUNCH_BUY_BPS`) and
emitted as `LaunchBuy(to, ethIn, hiveOut)`.

## Build

```sh
forge build
```

Compiler settings (also in [`foundry.toml`](foundry.toml)): solc `0.8.26`, EVM `cancun`, optimizer on with 800 runs,
`viaIR = true`, metadata `bytecodeHash = none`, `appendCBOR = false`.

## Vendored dependencies

Only the files the contracts import are included, unmodified apart from line endings, under their original licenses:

| Path | Upstream | Commit | License |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core) | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` | see `lib/v4-core/licenses` and each file's SPDX header |
| `lib/v4-periphery` | [Uniswap/v4-periphery](https://github.com/Uniswap/v4-periphery) | `9969eec44cfdf07e24b41de47f40276a58401976` | MIT |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate) | `4b47a19038b798b4a33d9749d25e570443520647` | AGPL-3.0-only |

## License

HIVE's own contracts (`src/`) are MIT licensed — see [LICENSE](LICENSE).
