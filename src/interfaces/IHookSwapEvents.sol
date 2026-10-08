// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Standard event interface for custom-accounting hook swaps (URC-2 reference event, as published by
///         Programmable in src/interfaces/IHookSwapEvents.sol).
interface IHookSwapEvents {
    /// @param amount0 The hook delta for currency0 from the swapper perspective (negative = paid by the swapper).
    /// @param amount1 The hook delta for currency1 from the swapper perspective.
    /// @param swapFee The hook fee in pips, where 1_000_000 is 100%.
    event HookSwap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint24 swapFee);
}
