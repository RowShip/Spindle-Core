// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {SpindleVaultStorage} from "./abstract/SpindleVaultStorage.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "./libraries/FullMath.sol";

import {Uniswap} from "./libraries/Uniswap.sol";

uint256 constant Q96 = 2**96;

contract SpindleVault is IUniswapV3MintCallback, SpindleVaultStorage {
    using SafeERC20 for IERC20;
    using TickMath for int24;
    using Uniswap for Uniswap.Position;

    event Minted(
        address receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In,
        uint128 liquidityMinted
    );

    event Burned(
        address receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out,
        uint128 liquidityBurned
    );

    event Reinvest(
        int24 lowerTick_,
        int24 upperTick_,
        uint128 liquidityBefore,
        uint128 liquidityAfter
    );

    enum AuctionType {
        TIME,
        PRICE,
        IV
    }

    event Recenter(
        AuctionType auctionType,
        uint256 auctionTriggerTime,
        int24 lowerTick_,
        int24 upperTick_,
        uint256 amount0Exchanged,
        uint256 amount1Exchanged,
        bool zeroForOne
    );

    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);

    /// @notice Uniswap V3 callback fn
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /*_data*/
    ) external override {
        require(msg.sender == address(pool), "callback caller");

        if (amount0Owed != 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) token1.safeTransfer(msg.sender, amount1Owed);
    }

    // User functions => Should be called via a Router

    /// @notice mint fungible SS-UNI tokens, fractional shares of a Uniswap V3 position
    /// @dev to compute the amouint of tokens necessary to mint `mintAmount` see getMintAmounts
    /// @param mintAmount The number of SS-UNI tokens to mint
    /// @param receiver The account to receive the minted tokens
    /// @return amount0 amount of token0 transferred from msg.sender to mint `mintAmount`
    /// @return amount1 amount of token1 transferred from msg.sender to mint `mintAmount`
    /// @return liquidityMinted amount of liquidity added to the underlying Uniswap V3 position
    // solhint-disable-next-line function-max-lines, code-complexity
    function mint(uint256 mintAmount, address receiver)
        external
        returns (
            uint256 amount0,
            uint256 amount1,
            uint128 liquidityMinted
        )
    {
        require(mintAmount > 0, "mint 0");

        uint256 totalSupply = totalSupply();

        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        packedSlot.locked = true;

        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        uint256 amount0Current;
        uint256 amount1Current;
        InventoryDetails memory d;

        if (totalSupply > 0) {
            (amount0Current, amount1Current, d) = _getUnderlyingBalances(
                primary,
                limit,
                sqrtRatioX96
            );

            amount0 = FullMath.mulDivRoundingUp(
                amount0Current,
                mintAmount,
                totalSupply
            );
            amount1 = FullMath.mulDivRoundingUp(
                amount1Current,
                mintAmount,
                totalSupply
            );
        } else {
            // if supply is 0 mintAmount == liquidity to deposit
            (amount0, amount1) = primary.amountsForLiquidity(
                sqrtRatioX96,
                SafeCast.toUint128(mintAmount)
            );
        }

        // transfer amounts owed to contract
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        // If limit order is open place a proportional
        // amount of tokens across both limit order
        // and primary position. If no limit order is open,
        // place all tokens across the primary position.
        if (d.limitLiquidity != 0) {
            d.amount0Limit = FullMath.mulDivRoundingUp(
                d.amount0Limit,
                mintAmount,
                totalSupply
            );
            d.amount1Limit = FullMath.mulDivRoundingUp(
                d.amount1Limit,
                mintAmount,
                totalSupply
            );
            liquidityMinted = limit.liquidityForAmounts(
                sqrtRatioX96,
                d.amount0Limit,
                d.amount1Limit
            );
            (d.amount0Limit, d.amount1Limit) = limit.deposit(liquidityMinted);
            // Deposit as much liquidity as possible into the primary position
            // using remaing tokens
            liquidityMinted += primary.liquidityForAmounts(
                sqrtRatioX96,
                amount0 - d.amount0Limit,
                amount1 - d.amount1Limit
            );
            primary.deposit(liquidityMinted);
        } else {
            // deposit as much new liquidity as possible into primary
            liquidityMinted = primary.liquidityForAmounts(
                sqrtRatioX96,
                amount0,
                amount1
            );
            primary.deposit(liquidityMinted);
        }
        _mint(receiver, mintAmount);
        emit Minted(receiver, mintAmount, amount0, amount1, liquidityMinted);
        packedSlot.locked = false;
    }

    /// @notice burn SS-UNI tokens (fractional shares of a Uniswap V3 position) and receive tokens
    /// @param burnAmount The number of SS-UNI tokens to burn
    /// @param receiver The account to receive the underlying amounts of token0 and token1
    /// @return amount0 amount of token0 transferred to receiver for burning `burnAmount`
    /// @return amount1 amount of token1 transferred to receiver for burning `burnAmount`
    /// @return liquidityBurned amount of liquidity removed from the underlying Uniswap V3 position
    // solhint-disable-next-line function-max-lines
    struct BurnCache {
        uint256 burn0;
        uint256 burn1;
        uint256 fee0;
        uint256 fee1;
    }

    function burn(uint256 burnAmount, address receiver)
        external
        returns (
            uint256 amount0,
            uint256 amount1,
            uint128 liquidityBurned
        )
    {
        require(burnAmount > 0, "burn 0");

        uint256 totalSupply = totalSupply();

        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        packedSlot.locked = true;

        (uint128 liquidity, , , , ) = primary.info();

        _burn(msg.sender, burnAmount);

        BurnCache memory cache;

        uint256 liquidityBurned_ = FullMath.mulDiv(
            burnAmount,
            liquidity,
            totalSupply
        );

        liquidityBurned = SafeCast.toUint128(liquidityBurned_);

        (cache.burn0, cache.burn1, cache.fee0, cache.fee1) = primary.withdraw(
            liquidityBurned
        );

        // Withdraw portion of limit order
        if (limit.upper != limit.lower) {
            (liquidity, , , , ) = limit.info();

            liquidityBurned_ = FullMath.mulDiv(
                burnAmount,
                liquidity,
                totalSupply
            );
            liquidityBurned += SafeCast.toUint128(liquidityBurned_);

            (uint256 burn0, uint256 burn1, , ) = limit.withdraw(
                liquidityBurned
            );

            cache.burn0 += burn0;
            cache.burn1 += burn1;
        }
        _applyFees(cache.fee0, cache.fee1);
        (cache.fee0, cache.fee1) = _subtractAdminFees(cache.fee0, cache.fee1);
        emit FeesEarned(cache.fee0, cache.fee1);

        amount0 =
            cache.burn0 +
            FullMath.mulDiv(
                token0.balanceOf(address(this)) - cache.burn0 - managerBalance0,
                burnAmount,
                totalSupply
            );
        amount1 =
            cache.burn1 +
            FullMath.mulDiv(
                token1.balanceOf(address(this)) - cache.burn1 - managerBalance1,
                burnAmount,
                totalSupply
            );

        if (amount0 > 0) {
            token0.safeTransfer(receiver, amount0);
        }

        if (amount1 > 0) {
            token1.safeTransfer(receiver, amount1);
        }

        emit Burned(receiver, burnAmount, amount0, amount1, liquidityBurned);
        packedSlot.locked = false;
    }

    /// @notice Reinvest fees earned into primary position. Excess gets deposited into limit order

    function reinvest() external {
        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        packedSlot.locked = true;

        (uint128 liquidity, , , , ) = primary.info();

        uint256 leftover0;
        uint256 leftover1;

        // withdraw limit order.
        if (limit.lower != limit.upper) {
            (uint128 liquidityL, , , , ) = limit.info();
            (uint256 burned0, uint256 burned1, , ) = limit.withdraw(liquidityL);
            leftover0 =
                token0.balanceOf(address(this)) -
                managerBalance0 -
                burned0;
            leftover1 =
                token1.balanceOf(address(this)) -
                managerBalance1 -
                burned1;
        } else {
            leftover0 = token0.balanceOf(address(this)) - managerBalance0;
            leftover1 = token1.balanceOf(address(this)) - managerBalance1;
        }

        _reinvest(primary, limit, liquidity, leftover0, leftover1);

        (uint128 newLiquidity, , , , ) = primary.info();

        require(newLiquidity > liquidity, "liquidity must increase");

        emit Reinvest(primary.lower, primary.upper, liquidity, newLiquidity);
        packedSlot.locked = false;
    }

    struct RecenterCache {
        uint160 sqrtPriceX96;
        uint224 priceX96;
        int24 tick;
        uint256 iv;
    }

    /// @notice Strategy recentering based on time threshold
    /// @param amount0Min minimum amount of token0 to receive
    /// @param amount1Min minimum amount of token1 to receive
    function timeRecenter(uint256 amount0Min, uint256 amount1Min) external {
        // check if recentering based on time threshold is allowed
        uint256 auctionTimestamp = timeAtLastRecenter + timeThreshold;

        require(
            block.timestamp >= auctionTimestamp,
            "time threshold not reached"
        );

        RecenterCache memory cache = _populateRecenterCache(pool);

        require(
            getAbsDiff(cache.tick, tickAtLastRecenter) >=
                int24(minTickThreshold),
            "tickDelta >= minTickThreshold"
        );

        _executeAuction(auctionTimestamp, amount0Min, amount1Min, cache);
    }

    /// @notice Strategy recentering based on tick threshold
    /// @param auctionTriggerTime time when tick threshold was triggered
    /// @param amount0Min minimum amount of token0 to receive
    /// @param amount1Min minimum amount of token1 to receive
    function tickRecenter(
        uint256 auctionTriggerTime,
        uint256 amount0Min,
        uint256 amount1Min
    ) external {
        require(
            auctionTriggerTime > block.timestamp,
            "auctionTriggerTime > timeAtLastRebalance"
        );
        uint32 secondsToTrigger = uint32(block.timestamp - auctionTriggerTime);

        int24 tickAtTrigger = SpindleOracle.getHistoricalTwap(
            pool,
            secondsToTrigger + TWAP_PERIOD,
            secondsToTrigger
        );

        RecenterCache memory cache = _populateRecenterCache(pool);

        require(
            getAbsDiff(tickAtLastRecenter, tickAtTrigger) >= int24(tickThreshold),
            "tickDelta >= tickThreshold"
        );

        _executeAuction(auctionTriggerTime, amount0Min, amount1Min, cache);
    }

    /// @notice Strategy recentering based on iv threshold
    /// @param amount0Min minimum amount of token0 to receive
    /// @param amount1Min minimum amount of token1 to receive
    function ivRecenter(uint256 amount0Min, uint256 amount1Min) external {
        require(
            block.timestamp >= (timeAtLastRecenter + timeThreshold),
            "time threshold not reached"
        );

        RecenterCache memory cache = _populateRecenterCache(pool);

        uint256 ratio = FullMath.mulDiv(
            10_000,
            cache.iv > ivAtLastRecenter ? cache.iv - ivAtLastRecenter : ivAtLastRecenter - cache.iv,
            ivAtLastRecenter
        );

        require(ratio >= ivThresholdBPS, "ivDelta >= ivThreshold");

        _executeAuction(
            block.timestamp + AUCTION_TIME, // skip to the end of auction for IV recentering
            amount0Min,
            amount1Min,
            cache
        );
    }

    /// @notice Populates recenter cache with price related pool data
    /// @return cache contains data needed for recenter computations
    function _populateRecenterCache(IUniswapV3Pool pool)
        internal
        returns (RecenterCache memory cache)
    {
        (cache.sqrtPriceX96, cache.tick, , , , , ) = pool.slot0();
        cache.priceX96 = uint224(
            FullMath.mulDiv(cache.sqrtPriceX96, cache.sqrtPriceX96, Q96)
        );
        cache.iv = SpindleOracle.estimate24H(pool);
    }

    function _executeAuction(
        uint256 auctionTimestamp,
        uint256 amount0Min,
        uint256 amount1Min,
        RecenterCache memory cache
    ) internal {
        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        packedSlot.locked = true;

        // Withdraw all the liqudity and collect fees
        if (limit.lower != limit.upper) {
            (uint128 liquidityL, , , , ) = limit.info();
            limit.withdraw(liquidityL);
        }

        (uint128 liquidity, , , , ) = primary.info();

        (, , uint256 feesEarned0, uint256 feesEarned1) = primary.withdraw(
            liquidity
        );
        _applyFees(feesEarned0, feesEarned1);
        (feesEarned0, feesEarned1) = _subtractAdminFees(
            feesEarned0,
            feesEarned1
        );
        emit FeesEarned(feesEarned0, feesEarned1);

        // Decide primary position width based on IV
        int24 w = _computeNextPositionWidth(cache.iv);
        w = w >> 1;

        // Update primary position's ticks
        unchecked {
            primary.lower = TickMath.floor(cache.tick - w, TICK_SPACING);
            primary.upper = TickMath.ceil(cache.tick + w, TICK_SPACING);
            if (primary.lower < MIN_TICK) primary.lower = MIN_TICK;
            if (primary.upper > MAX_TICK) primary.upper = MAX_TICK;
        }

        (uint256 amount0, uint256 amount1, bool zeroForOne) = _getAuctionParams(
            primary,
            cache,
            auctionTimestamp
        );

        if (zeroForOne) {
            require(amount0 >= amount0Min, "amount0Min not reached");
            token0.safeTransfer(msg.sender, amount0);
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        } else {
            require(amount1 >= amount1Min, "amount1Min not reached");
            token1.safeTransfer(msg.sender, amount1);
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }

        // Place new primary position
        primary.deposit(
            primary.liquidityForAmounts(
                cache.sqrtPriceX96,
                token0.balanceOf(address(this)) - managerBalance0,
                token1.balanceOf(address(this)) - managerBalance1
            )
        );

        emit Recenter(
            AuctionType.TIME,
            auctionTimestamp,
            primary.lower,
            primary.upper,
            amount0,
            amount1,
            zeroForOne
        );

        timeAtLastRecenter = uint48(block.timestamp);
        tickAtLastRecenter = cache.tick;
        ivAtLastRecenter = cache.iv;

        packedSlot = PackedSlot(
            primary.lower,
            primary.upper,
            limit.lower,
            limit.upper,
            false
        );
    }

    /// @dev calculate auction parameters
    /// @param cache memory cache
    /// @return amount0 to be exchanged with keeper
    /// @return amount1 to be exchanged with keeper
    /// @return zeroForOne true if token0 is the auctioned token sent to keeper, false otherwise
    function _getAuctionParams(
        Uniswap.Position memory primary,
        RecenterCache memory cache,
        uint256 auctionTimestamp
    )
        private
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            bool zeroForOne
        )
    {
        // get current amounts
        uint256 amount0Current = token0.balanceOf(address(this)) -
            managerBalance0;
        uint256 amount1Current = token1.balanceOf(address(this)) -
            managerBalance1;

        // compute total maximum deposit at new ticks
        (uint128 liquidity, bool limitedBy0) = primary.liquidityForAmountsCheck(
            cache.sqrtPriceX96,
            amount0Current,
            amount1Current
        );
        (amount0, amount1) = primary.amountsForLiquidity(
            cache.sqrtPriceX96,
            liquidity
        );

        // compute the auction price multiplier
        uint16 priceMultiplier = block.timestamp - auctionTimestamp >=
            AUCTION_TIME
            ? MAX_PRICE_MULTIPLIER_BPS
            : MAX_PRICE_MULTIPLIER_BPS -
                uint16(
                    FullMath.mulDiv(
                        block.timestamp - auctionTimestamp,
                        (MAX_PRICE_MULTIPLIER_BPS - MIN_PRICE_MULTIPLIER_BPS),
                        AUCTION_TIME
                    )
                );

        uint256 discountedPrice;
        uint256 ratio;
        if (limitedBy0) {
            // Discount the price of token1.
            // Presumably the keeper waits until priceMultiplier < 10000 to achieve an arb profit.
            discountedPrice = FullMath.mulDiv(
                cache.priceX96,
                10_000,
                priceMultiplier
            );
            // compute proportion of token0 total value in the position
            ratio = FullMath.mulDiv(
                10_000,
                amount0,
                amount0 +
                    FullMath.mulDiv(
                        amount1,
                        Q96,
                        discountedPrice // Discount the price of excess token
                    )
            );
            // compute the amount of token1 to be swapped with keeper
            amount1 = FullMath.mulDiv(amount1Current - amount1, ratio, 10_000);
            amount0 = FullMath.mulDiv(amount1, Q96, discountedPrice);
        } else {
            zeroForOne = true;
            // Discount the price of token0.
            // Presumably the keeper waits until priceMultiplier < 10000 to achieve an arb profit.
            discountedPrice = FullMath.mulDiv(
                cache.priceX96,
                priceMultiplier,
                10_000
            );
            // compute proportion of token1 total value in the position
            ratio = FullMath.mulDiv(
                10_000,
                amount1,
                amount1 +
                    FullMath.mulDiv(
                        amount0,
                        discountedPrice, // Discount the price of excess token
                        Q96
                    )
            );
            // compute the amount of token0 to be swapped with keeper
            amount0 = FullMath.mulDiv(amount0Current - amount0, ratio, 10_000);
            amount1 = FullMath.mulDiv(amount0, discountedPrice, Q96);
        }
    }

    /// @dev Computes position width based on volatility. Doesn't revert
    /// @dev ExpectedMove = P0 * IV * sqrt(T)
    function _computeNextPositionWidth(uint256 _sigma)
        internal
        view
        returns (int24)
    {
        if (_sigma <= A) return MIN_WIDTH; // \frac{1e18}{B} (1 - \frac{1}{1.0001^(MIN_WIDTH / 2*sqrt(7))})
        if (_sigma >= C) return MAX_WIDTH; // \frac{1e18}{B} (1 - \frac{1}{1.0001^(MAX_WIDTH / 2*sqrt(7))})
        _sigma *= B;
        unchecked {
            uint160 ratio = uint160((Q96 * 1e18) / (1e18 - _sigma));
            return TickMath.getTickAtSqrtRatio(ratio);
        }
    }

    /// @notice withdraw manager fees accrued
    function withdrawManagerBalance() external {
        uint256 amount0 = managerBalance0;
        uint256 amount1 = managerBalance1;

        managerBalance0 = 0;
        managerBalance1 = 0;

        if (amount0 > 0) {
            token0.safeTransfer(managerTreasury, amount0);
        }

        if (amount1 > 0) {
            token1.safeTransfer(managerTreasury, amount1);
        }
    }

    // View functions

    /// @notice Computes |a - b|
    /// @return the absolute difference between a and b
    function getAbsDiff(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a - b : b - a;
    }

    /// @notice compute maximum SS-UNI tokens that can be minted from `amount0Max` and `amount1Max`
    /// @param amount0Max The maximum amount of token0 to forward on mint
    /// @param amount1Max The maximum amount of token1 to forward on mint
    /// @return amount0 actual amount of token0 to forward when minting `mintAmount`
    /// @return amount1 actual amount of token1 to forward when minting `mintAmount`
    /// @return mintAmount maximum number of SS-UNI tokens to mint
    function getMintAmounts(uint256 amount0Max, uint256 amount1Max)
        external
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 mintAmount
        )
    {
        uint256 totalSupply = totalSupply();
        if (totalSupply > 0) {
            (amount0, amount1, mintAmount) = _computeMintAmounts(
                totalSupply,
                amount0Max,
                amount1Max
            );
        } else {
            (Uniswap.Position memory primary, ) = _loadPackedSlot();
            (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
            uint128 newLiquidity = primary.liquidityForAmounts(
                sqrtRatioX96,
                amount0Max,
                amount1Max
            );
            mintAmount = uint256(newLiquidity);
            (amount0, amount1) = primary.amountsForLiquidity(
                sqrtRatioX96,
                newLiquidity
            );
        }
    }

    /// @notice compute total underlying holdings of the SS-UNI token supply
    /// includes current liquidity invested in uniswap position, current fees earned, limit order
    /// and any uninvested leftover (but does not include manager and treasury fees accrued)
    /// @return amount0Current current total underlying balance of token0
    /// @return amount1Current current total underlying balance of token1
    function getUnderlyingBalances()
        public
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        (amount0Current, amount1Current, ) = _getUnderlyingBalances(
            primary,
            limit,
            sqrtRatioX96
        );
    }

    function getUnderlyingBalancesAtPrice(uint160 sqrtRatioX96)
        external
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (
            Uniswap.Position memory primary,
            Uniswap.Position memory limit
        ) = _loadPackedSlot();
        (amount0Current, amount1Current, ) = _getUnderlyingBalances(
            primary,
            limit,
            sqrtRatioX96
        );
    }

    // solhint-disable-next-line function-max-lines
    struct InventoryDetails {
        // The amount of token0 inside limit order excluding earned fees
        uint256 amount0Limit;
        // The amount of token1 inside limit order excluding earned fees
        uint256 amount1Limit;
        // The liquidity present in the primary position. Note that this may be higher than what the
        // vault deposited since someone may designate this contract as a `mint()` recipient
        uint128 primaryLiquidity;
        // The liquidity present in the limit order. Note that this may be higher than what the
        // vault deposited since someone may designate this contract as a `mint()` recipient
        uint128 limitLiquidity;
    }

    function _getUnderlyingBalances(
        Uniswap.Position memory _primary,
        Uniswap.Position memory _limit,
        uint160 _sqrtPriceX96
    )
        internal
        returns (
            uint256 amount0Current,
            uint256 amount1Current,
            InventoryDetails memory d
        )
    {
        // poke primary position so earned fees are updated
        _primary.poke();

        (
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _primary.info();

        d.primaryLiquidity = liquidity;

        // compute current holdings from d.primaryLiquidity
        (amount0Current, amount1Current) = _primary.amountsForLiquidity(
            _sqrtPriceX96,
            d.primaryLiquidity
        );

        // If the limit order has been placed to recenter then
        // compute underlying balance of the limit position
        // including the earned trading fees.
        if (_limit.upper != _limit.lower) {
            uint128 tokensOwed0L;
            uint128 tokensOwed1L;
            (d.limitLiquidity, , , tokensOwed0L, tokensOwed1L) = _limit.info();
            (d.amount0Limit, d.amount1Limit) = _limit.amountsForLiquidity(
                _sqrtPriceX96,
                d.limitLiquidity
            );
            amount0Current += d.amount0Limit + tokensOwed0L;
            amount1Current += d.amount1Limit + tokensOwed1L;
        }
        // compute current fees earned from primary position
        uint256 fee0 = uint256(tokensOwed0);
        uint256 fee1 = uint256(tokensOwed1);

        (fee0, fee1) = _subtractAdminFees(fee0, fee1);

        // add any leftover in contract to current holdings
        amount0Current +=
            fee0 +
            token0.balanceOf(address(this)) -
            managerBalance0;
        amount1Current +=
            fee1 +
            token1.balanceOf(address(this)) -
            managerBalance1;
    }

    // solhint-disable-next-line function-max-lines
    function _reinvest(
        Uniswap.Position memory primary,
        Uniswap.Position memory limit,
        uint128 primaryLiquidity,
        uint256 leftover0,
        uint256 leftover1
    ) private {
        (, , uint256 feesEarned0, uint256 feesEarned1) = primary.withdraw(
            primaryLiquidity
        );
        _applyFees(feesEarned0, feesEarned1);
        (feesEarned0, feesEarned1) = _subtractAdminFees(
            feesEarned0,
            feesEarned1
        );
        emit FeesEarned(feesEarned0, feesEarned1);
        feesEarned0 += leftover0;
        feesEarned1 += leftover1;

        token0.safeTransfer(msg.sender, (feesEarned0 * reinvestBPS) / 10000);
        token1.safeTransfer(msg.sender, (feesEarned1 * reinvestBPS) / 10000);

        leftover0 = token0.balanceOf(address(this)) - managerBalance0;
        leftover1 = token1.balanceOf(address(this)) - managerBalance1;

        (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();

        _deposit(primary, limit, leftover0, leftover1, sqrtRatioX96, tick);
    }

    function _loadPackedSlot()
        private
        view
        returns (Uniswap.Position memory, Uniswap.Position memory)
    {
        PackedSlot memory _packedSlot = packedSlot;
        require(!_packedSlot.locked);
        return (
            Uniswap.Position(
                pool,
                _packedSlot.primaryLower,
                _packedSlot.primaryUpper
            ),
            Uniswap.Position(
                pool,
                _packedSlot.limitLower,
                _packedSlot.limitUpper
            )
        );
    }

    // solhint-disable-next-line function-max-lines
    function _deposit(
        Uniswap.Position memory primary,
        Uniswap.Position memory limit,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtRatioX96,
        int24 tick
    ) private {
        // First, deposit as much as we can
        (uint128 baseLiquidity, bool limitedBy0) = primary
            .liquidityForAmountsCheck(sqrtRatioX96, amount0, amount1);

        if (baseLiquidity != 0) {
            (uint256 amountDeposited0, uint256 amountDeposited1) = primary
                .deposit(baseLiquidity);

            amount0 -= amountDeposited0;
            amount1 -= amountDeposited1;
        }

        bool zeroForOne = baseLiquidity != 0 ? !limitedBy0 : amount0 > amount1;
        // Put left over token into limit order.
        if (zeroForOne) {
            // Choose limit order bounds above the market price.
            limit.lower = TickMath.ceil(tick, TICK_SPACING);
            limit.upper = limit.lower + TICK_SPACING;
            // place a new limit order
            limit.deposit(limit.liquidityForAmount0(amount0));
        } else {
            // Choose limit order bounds below the market price.
            limit.upper = TickMath.floor(tick, TICK_SPACING);
            limit.lower = limit.upper - TICK_SPACING;
            // place a new limit order
            limit.deposit(limit.liquidityForAmount1(amount1));
        }
        packedSlot.limitLower = limit.lower;
        packedSlot.limitUpper = limit.upper;
    }

    // solhint-disable-next-line function-max-lines, code-complexity
    function _computeMintAmounts(
        uint256 totalSupply,
        uint256 amount0Max,
        uint256 amount1Max
    )
        private
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 mintAmount
        )
    {
        (
            uint256 amount0Current,
            uint256 amount1Current
        ) = getUnderlyingBalances();

        // compute proportional amount of tokens to mint
        if (amount0Current == 0 && amount1Current > 0) {
            mintAmount = FullMath.mulDiv(
                amount1Max,
                totalSupply,
                amount1Current
            );
        } else if (amount1Current == 0 && amount0Current > 0) {
            mintAmount = FullMath.mulDiv(
                amount0Max,
                totalSupply,
                amount0Current
            );
        } else if (amount0Current == 0 && amount1Current == 0) {
            revert("");
        } else {
            // only if both are non-zero
            uint256 amount0Mint = FullMath.mulDiv(
                amount0Max,
                totalSupply,
                amount0Current
            );
            uint256 amount1Mint = FullMath.mulDiv(
                amount1Max,
                totalSupply,
                amount1Current
            );
            require(amount0Mint > 0 && amount1Mint > 0, "mint 0");

            mintAmount = amount0Mint < amount1Mint ? amount0Mint : amount1Mint;
        }

        // compute amounts owed to contract
        amount0 = FullMath.mulDivRoundingUp(
            mintAmount,
            amount0Current,
            totalSupply
        );
        amount1 = FullMath.mulDivRoundingUp(
            mintAmount,
            amount1Current,
            totalSupply
        );
    }

    function _applyFees(uint256 _fee0, uint256 _fee1) private {
        managerBalance0 += (_fee0 * managerFeeBPS) / 10000;
        managerBalance1 += (_fee1 * managerFeeBPS) / 10000;
    }

    function _subtractAdminFees(uint256 rawFee0, uint256 rawFee1)
        private
        view
        returns (uint256 fee0, uint256 fee1)
    {
        uint256 deduct0 = (rawFee0 * (managerFeeBPS)) / 10000;
        uint256 deduct1 = (rawFee1 * (managerFeeBPS)) / 10000;
        fee0 = rawFee0 - deduct0;
        fee1 = rawFee1 - deduct1;
    }
}
