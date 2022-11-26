// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.10;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {FullMath} from "./FullMath.sol";
import "./TickMath.sol";

/// @title Oracle
/// @notice Provides functions to integrate with V3 pool oracle
library Oracle {
    
    /// @notice fetches time-weighted average tick using uniswap v3 oracle
    /// @dev written by opyn team
    /// @param pool Address of uniswap v3 pool that we want to observe
    /// @param _secondsAgoToStartOfTwap number of seconds to start of TWAP period
    /// @param _secondsAgoToEndOfTwap number of seconds to end of TWAP period
    /// @return arithmeticMeanTick The arithmetic mean tick from (block.timestamp - secondsAgo) to block.timestamp
    /// @return secondsPerLiquidityX128 The change in seconds per liquidity from (block.timestamp - secondsAgo)
    /// to block.timestamp

    function consultAtHistoricTime(
        IUniswapV3Pool pool,
        uint32 _secondsAgoToStartOfTwap,
        uint32 _secondsAgoToEndOfTwap
    ) internal view returns (int24 arithmeticMeanTick, uint160 secondsPerLiquidityX128)
    {
        require(_secondsAgoToStartOfTwap > _secondsAgoToEndOfTwap, "BP");
        uint32[] memory secondAgos = new uint32[](2);

        uint32 twapDuration = _secondsAgoToStartOfTwap - _secondsAgoToEndOfTwap;

        // get TWAP from (now - _secondsAgoToStartOfTwap) -> (now - _secondsAgoToEndOfTwap)
        secondAgos[0] = _secondsAgoToStartOfTwap;
        secondAgos[1] = _secondsAgoToEndOfTwap;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = pool.observe(
            secondAgos
        );

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        arithmeticMeanTick = int24(tickCumulativesDelta / int32(twapDuration));
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int32(twapDuration) != 0)) arithmeticMeanTick--;

        secondsPerLiquidityX128 = secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];
    }

    /**
     * @notice Given a pool, it returns the number of seconds ago of the oldest stored observation
     * @param pool Address of Uniswap V3 pool that we want to observe
     * @param observationIndex The observation index from pool.slot0()
     * @param observationCardinality The observationCardinality from pool.slot0()
     * @dev (, , uint16 observationIndex, uint16 observationCardinality, , , ) = pool.slot0();
     * @return secondsAgo The number of seconds ago that the oldest observation was stored
     */
    function getMaxSecondsAgo(
        IUniswapV3Pool pool,
        uint16 observationIndex,
        uint16 observationCardinality
    ) internal view returns (uint32 secondsAgo) {
        require(observationCardinality != 0, "NI");

        unchecked {
            (uint32 observationTimestamp, , , bool initialized) = pool.observations(
                (observationIndex + 1) % observationCardinality
            );

            // The next index might not be initialized if the cardinality is in the process of increasing
            // In this case the oldest observation is always in index 0
            if (!initialized) {
                (observationTimestamp, , , ) = pool.observations(0);
            }

            secondsAgo = uint32(block.timestamp) - observationTimestamp;
        }
    }
}
