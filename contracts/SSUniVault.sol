// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {SSUniVaultStorage} from "./abstract/SSUniVaultStorage.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "./libraries/FullMath.sol";

import { Uniswap } from "./libraries/Uniswap.sol";

uint256 constant Q96 = 2**96;

contract SSUniVault is
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    SSUniVaultStorage
{
    using SafeERC20 for IERC20;
    using TickMath for int24;
    using Uniswap for Uniswap.Position;

    enum Limit {
        Opened,
        Closed
    }

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

    event Rebalance(
        int24 lowerTick_,
        int24 upperTick_,
        uint128 liquidityBefore,
        uint128 liquidityAfter
    );

    event Recenter(
        int24 lowerTick_,
        int24 upperTick_,
        Limit indexed step
    );

    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);

    // solhint-disable-next-line max-line-length
    constructor(address payable _gelato) SSUniVaultStorage(_gelato) {} // solhint-disable-line no-empty-blocks

    /// @notice Uniswap V3 callback fn, called back on pool.mint
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /*_data*/
    ) external override {
        require(msg.sender == address(pool), "callback caller");

        if (amount0Owed > 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.safeTransfer(msg.sender, amount1Owed);
    }

    /// @notice Uniswap v3 callback fn, called back on pool.swap
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /*data*/
    ) external override {
        require(msg.sender == address(pool), "callback caller");

        if (amount0Delta > 0)
            token0.safeTransfer(msg.sender, uint256(amount0Delta));
        else if (amount1Delta > 0)
            token1.safeTransfer(msg.sender, uint256(amount1Delta));
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
        nonReentrant
        returns (
            uint256 amount0,
            uint256 amount1,
            uint128 liquidityMinted
        )
    {
        require(mintAmount > 0, "mint 0");

        uint256 totalSupply = totalSupply();

        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();

        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        uint256 amount0Current;
        uint256 amount1Current;
        InventoryDetails memory d;

        if (totalSupply > 0) {
            (
                amount0Current,
                amount1Current,
                d
            ) = _getUnderlyingBalances(primary, limit, sqrtRatioX96);

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
        if(d.limitLiquidity != 0) {
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
        nonReentrant
        returns (
            uint256 amount0,
            uint256 amount1,
            uint128 liquidityBurned
        )
    {
        require(burnAmount > 0, "burn 0");

        uint256 totalSupply = totalSupply();

        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();


        (uint128 liquidity, , , , ) = primary.info();

        _burn(msg.sender, burnAmount);

        BurnCache memory cache;

        uint256 liquidityBurned_ = FullMath.mulDiv(
            burnAmount,
            liquidity,
            totalSupply
        );

        liquidityBurned = SafeCast.toUint128(liquidityBurned_);

        (cache.burn0, cache.burn1, cache.fee0, cache.fee1) = primary.withdraw(liquidityBurned);

        // Withdraw portion of limit order
        if (limit.upper != limit.lower) {
            (liquidity, , , , ) = limit.info();
            BurnCache memory cacheL;

            liquidityBurned_ = FullMath.mulDiv(
                burnAmount,
                liquidity,
                totalSupply
            );
            liquidityBurned += SafeCast.toUint128(liquidityBurned_);

            (cacheL.burn0, cacheL.burn1, cacheL.fee0, cacheL.fee1) = limit.withdraw(liquidityBurned);

            cache.burn0 += cacheL.burn0;
            cache.burn1 += cacheL.burn1;
            // All of the fees earned from limit gets paid to manager
            managerBalance0 += cacheL.fee0;
            managerBalance1 += cacheL.fee1;
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
    }

    // Gelatofied functions => Automatically called by Gelato

    /// @notice Reinvest fees earned into underlying position, only gelato executors can call
    /// @dev Can only rebalance primary uniswap position when there is no limit order open
    /// Position bounds CANNOT be altered by gelato, only manager may via executiveRebalance.
    /// Frequency of rebalance configured with gelatoRebalanceBPS, alterable by manager.
    /// Create resolver function for rebalance. Call it checkCanRebalance()
    /// Make it to where it generates the swapAmountBPS parameter by simulating the entire operation.
    function reinvest(
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne,
        uint256 feeAmount,
        address paymentToken
    ) external gelatofy(feeAmount, paymentToken) {

        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();

        require(
            limit.upper == limit.lower,
            "Can't rebalance when limit order is open"
        );

        if (swapAmountBPS > 0) _checkSlippage(swapThresholdPrice, zeroForOne);
        
        (uint128 liquidity, , , , ) = primary.info();
        _reinvest(
            primary,
            liquidity,
            swapThresholdPrice,
            swapAmountBPS,
            zeroForOne,
            feeAmount,
            paymentToken
        );

        (uint128 newLiquidity, , , , ) = primary.info();
        require(newLiquidity > liquidity, "liquidity must increase");

        emit Rebalance(primary.lower, primary.upper, liquidity, newLiquidity);
    }

    /// @notice Recenters primary UniswapV3 position around current tick
    /// by intellegintly placing limit orders 
    /// as close to the current market price as possible 
    /// to achieve approx. 50/50 inventory ratio once pushed through.
    /// only gelato executor can call
    // solhint-disable-next-line function-max-lines

    // We place a limit order to get recenter the position.
    // Once limit order has been pushed through we call this function again.
    // Withdraw from the primary position and actually adjust the bounds of this position.
    struct RecenterCache {
        uint160 sqrtRatioX96;
        int24 tick;
        uint224 priceX96;
    }
    function recenter() external onlyGelato {
        Limit step;

        RecenterCache memory cache;

        (cache.sqrtRatioX96, cache.tick , , , , , ) = pool.slot0();

        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();

        (
            uint256 amount0Current,
            uint256 amount1Current,
            InventoryDetails memory d
        ) = _getUnderlyingBalances(primary, limit, cache.sqrtRatioX96);
        
        // Remove the limit order if it exists
        if (d.limitLiquidity != 0) {
            (, , uint256 fee0, uint256 fee1) = limit.withdraw(d.limitLiquidity);
            // All of the fees earned from limit gets paid to manager
            managerBalance0 += fee0;
            managerBalance1 += fee1;
        }
        // Compute inventory ratio to determine what happens next
        cache.priceX96 = uint224(FullMath.mulDiv(cache.sqrtRatioX96, cache.sqrtRatioX96, Q96));
        uint256 ratio = FullMath.mulDiv(
            10_000,
            amount0Current,
            amount0Current + FullMath.mulDiv(amount1Current, Q96, cache.priceX96)
        );
        if (ratio < 4900) {
            // Attempt to sell token1 for token0. Choose limit order bounds below the market price.
            limit.upper = TickMath.floor(cache.tick, TICK_SPACING);
            limit.lower = limit.upper - TICK_SPACING;
            // Choose amount1 such that ratio will be 50/50 once the limit order is pushed through (division by 2
            // is a good approximation for small tickSpacing). 
            uint256 amount1 = (amount1Current - FullMath.mulDiv(amount0Current, cache.priceX96, Q96)) >> 1;
            // If contract balance is insufficient, burn liquidity from primary. 
            unchecked {
                uint256 balance1 = token1.balanceOf(address(this)) - managerBalance1;
                if (balance1 < amount1) {
                    (, uint256 burned1) = primary.pool.burn(
                        primary.lower, 
                        primary.upper, 
                        primary.liquidityForAmount1(amount1 - balance1)
                    );
                    amount1 = balance1 + burned1;
                } 
            }
            // Place a new limit order
            limit.deposit(limit.liquidityForAmount1(amount1));
        } else if (ratio > 5100) {
            // Attempt to sell token0 for token1. Choose limit order bounds above the market price.
            limit.lower = TickMath.ceil(cache.tick, TICK_SPACING);
            limit.upper = limit.lower + TICK_SPACING;
            // Choose amount0 such that ratio will be 50/50 once the limit order is pushed through (division by 2
            // is a good approximation for small tickSpacing).
            uint256 amount0 = (amount0Current - FullMath.mulDiv(amount1Current, Q96, cache.priceX96)) >> 1;
            // If contract balance is insufficient, burn liquidity from primary. 
            unchecked {
                uint256 balance0 = token0.balanceOf(address(this)) - managerBalance0;
                if (balance0 < amount0) {
                    (uint256 burned0, ) = primary.pool.burn(
                        primary.lower, 
                        primary.upper, 
                        primary.liquidityForAmount0(amount0 - balance0)
                    );
                    amount0 = balance0 + burned0;
                } 
            }
            // Place a new limit order
            limit.deposit(limit.liquidityForAmount0(amount0));
        } else {
            step = Limit.Closed;
            // Zero-out the limit struct to indicate that it's inactive
            delete limit;
            primary = _recenter(cache.tick, cache.sqrtRatioX96, primary, d.primaryLiquidity);
        }
        emit Recenter(primary.lower, primary.upper, step);
        packedSlot = PackedSlot(
            primary.lower,
            primary.upper,
            limit.lower,
            limit.upper
        );
    }

    /**
     * @notice Recenters the primary Uniswap position around the current tick.
     * @dev This function assumes that the limit order has no liquidity (never existed or already exited)
     * @param tick The current pool tick
     * @param sqrtRatioX96 The current pool sqrtPriceX96
     * @param primary The existing primary Uniswap position
     * @param primaryLiquidity The amount of liquidity currently in `primary`
     * @return Uniswap.Position memory `primary` updated with new lower and upper tick bounds
     */
    function _recenter(
        int24 tick,
        uint160 sqrtRatioX96,
        Uniswap.Position memory primary,
        uint128 primaryLiquidity
    ) private returns (Uniswap.Position memory) {

        (, , uint256 feesEarned0, uint256 feesEarned1) = primary.withdraw(primaryLiquidity);
        _applyFees(feesEarned0, feesEarned1);
        (feesEarned0, feesEarned1) = _subtractAdminFees(
            feesEarned0,
            feesEarned1
        );
        emit FeesEarned(feesEarned0, feesEarned1);

        uint256 amount0 = token0.balanceOf(address(this)) - managerBalance0;
        uint256 amount1 = token1.balanceOf(address(this)) - managerBalance1;

        // Decide primary position width...
        int24 w =_computeNextPositionWidth(volatilityOracle.estimate24H(pool));
        w = w >> 1;

        // Update primary position's ticks
        unchecked {
            primary.lower = TickMath.floor(tick - w, TICK_SPACING);
            primary.upper = TickMath.ceil(tick + w, TICK_SPACING);
            if (primary.lower < MIN_TICK) primary.lower = MIN_TICK;
            if (primary.upper > MAX_TICK) primary.upper = MAX_TICK;
        }

        // Place some liquidity in Uniswap
        (amount0, amount1) = primary.deposit(primary.liquidityForAmounts(sqrtRatioX96, amount0, amount1));

        return primary;
    }

    /// @dev Computes position width based on volatility. Doesn't revert
    /// @dev ExpectedMove = P0 * IV * sqrt(T)
    function _computeNextPositionWidth(uint256 _sigma)
        internal
        pure
        returns (int24)
    {
        if (_sigma <= 3.760435956e15) return MIN_WIDTH; // \frac{1e18}{B} (1 - \frac{1}{1.0001^(MIN_WIDTH / 2*sqrt(7))})
        if (_sigma >= 1.417383935e17) return MAX_WIDTH; // \frac{1e18}{B} (1 - \frac{1}{1.0001^(MAX_WIDTH / 2*sqrt(7))})
        _sigma = FullMath.mulDiv(_sigma, B, 10_000); 
        unchecked {
            uint160 ratio = uint160((Q96 * 1e18) / (1e18 - _sigma));
            return TickMath.getTickAtSqrtRatio(ratio);
        }
    }

    /// @notice withdraw manager fees accrued
    function withdrawManagerBalance()
        external
    {
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
        (Uniswap.Position memory primary, ) = _loadPackedSlot();
        uint256 totalSupply = totalSupply();
        if (totalSupply > 0) {
            (amount0, amount1, mintAmount) = _computeMintAmounts(
                totalSupply,
                amount0Max,
                amount1Max
            );
        } else {
            (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
            uint128 newLiquidity = primary.liquidityForAmounts(sqrtRatioX96, amount0Max, amount1Max);
            mintAmount = uint256(newLiquidity);
            (amount0, amount1) = primary.amountsForLiquidity(sqrtRatioX96, newLiquidity);
        }
    }



    /// @notice compute total underlying holdings of the SS-UNI token supply
    /// includes current liquidity invested in uniswap position, current fees earned, limit order
    /// and any uninvested leftover (but does not include manager fees accrued)
    /// @return amount0Current current total underlying balance of token0
    /// @return amount1Current current total underlying balance of token1
    function getUnderlyingBalances()
        public
        returns (
            uint256 amount0Current,
            uint256 amount1Current
        )
    {
        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        (amount0Current, amount1Current,)= _getUnderlyingBalances(primary, limit, sqrtRatioX96);
    }

    function getUnderlyingBalancesAtPrice(uint160 sqrtRatioX96)
        external
        returns (
            uint256 amount0Current,
            uint256 amount1Current
        )
    {
        (Uniswap.Position memory primary, Uniswap.Position memory limit) = _loadPackedSlot();
        (amount0Current, amount1Current,)= _getUnderlyingBalances(primary, limit, sqrtRatioX96);
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
        // excluding the earned trading fees. 100 percent of earned
        // limit order fees are paid to the manager.
        if (_limit.upper != _limit.lower) {
            ( d.limitLiquidity, , , , ) = _limit.info();
            (d.amount0Limit, d.amount1Limit) = _limit.amountsForLiquidity(
                _sqrtPriceX96,
                 d.limitLiquidity
            );
            amount0Current += d.amount0Limit;
            amount1Current += d.amount1Limit;
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


    // Private functions

    // solhint-disable-next-line function-max-lines
    function _reinvest(
        Uniswap.Position memory primary,
        uint128 liquidity,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne,
        uint256 feeAmount,
        address paymentToken
    ) private {
        uint256 leftover0 = token0.balanceOf(address(this)) - managerBalance0;
        uint256 leftover1 = token1.balanceOf(address(this)) - managerBalance1;

        (, , uint256 feesEarned0, uint256 feesEarned1) = primary.withdraw(liquidity);
        _applyFees(feesEarned0, feesEarned1);
        (feesEarned0, feesEarned1) = _subtractAdminFees(
            feesEarned0,
            feesEarned1
        );
        emit FeesEarned(feesEarned0, feesEarned1);
        feesEarned0 += leftover0;
        feesEarned1 += leftover1;

        if (paymentToken == address(token0)) {
            require(
                (feesEarned0 * gelatoRebalanceBPS) / 10000 >= feeAmount,
                "high fee"
            );
            leftover0 =
                token0.balanceOf(address(this)) -
                managerBalance0 -
                feeAmount;
            leftover1 = token1.balanceOf(address(this)) - managerBalance1;
        } else if (paymentToken == address(token1)) {
            require(
                (feesEarned1 * gelatoRebalanceBPS) / 10000 >= feeAmount,
                "high fee"
            );
            leftover0 = token0.balanceOf(address(this)) - managerBalance0;
            leftover1 =
                token1.balanceOf(address(this)) -
                managerBalance1 -
                feeAmount;
        } else {
            revert("wrong token");
        }

        _deposit(
            primary,
            leftover0,
            leftover1,
            swapThresholdPrice,
            swapAmountBPS,
            zeroForOne
        );
    }

    function _loadPackedSlot()
        private
        view
        returns (
            Uniswap.Position memory,
            Uniswap.Position memory
        )
    {
        PackedSlot memory _packedSlot = packedSlot;
        return (
            Uniswap.Position(pool, _packedSlot.primaryLower, _packedSlot.primaryUpper),
            Uniswap.Position(pool, _packedSlot.limitLower, _packedSlot.limitUpper)
        );
    }

    // solhint-disable-next-line function-max-lines
    function _deposit(
        Uniswap.Position memory primary,
        uint256 amount0,
        uint256 amount1,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) private {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        // First, deposit as much as we can
        uint128 baseLiquidity = primary.liquidityForAmounts(
            sqrtRatioX96,
            amount0,
            amount1
        );
        if (baseLiquidity > 0) {
            (uint256 amountDeposited0, uint256 amountDeposited1) = primary.deposit(baseLiquidity);

            amount0 -= amountDeposited0;
            amount1 -= amountDeposited1;
        }
        int256 swapAmount = SafeCast.toInt256(
            ((zeroForOne ? amount0 : amount1) * swapAmountBPS) / 10000
        );
        if (swapAmount > 0) {
            _swapAndDeposit(
                primary,
                amount0,
                amount1,
                swapAmount,
                swapThresholdPrice,
                zeroForOne
            );
        }
    }

    function _swapAndDeposit(
        Uniswap.Position memory primary,
        uint256 amount0,
        uint256 amount1,
        int256 swapAmount,
        uint160 swapThresholdPrice,
        bool zeroForOne
    ) private returns (uint256 finalAmount0, uint256 finalAmount1) {
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            zeroForOne,
            swapAmount,
            swapThresholdPrice,
            ""
        );
        finalAmount0 = uint256(SafeCast.toInt256(amount0) - amount0Delta);
        finalAmount1 = uint256(SafeCast.toInt256(amount1) - amount1Delta);

        // Add liquidity a second time
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        uint128 liquidityAfterSwap = primary.liquidityForAmounts(
            sqrtRatioX96,
            finalAmount0,
            finalAmount1
        );
        if (liquidityAfterSwap > 0) primary.deposit(liquidityAfterSwap);
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

    function _checkSlippage(uint160 swapThresholdPrice, bool zeroForOne)
        private
        view
    {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = gelatoSlippageInterval;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);

        require(tickCumulatives.length == 2, "array len");
        uint160 avgSqrtRatioX96;
        unchecked {
            int24 avgTick = int24(
                (tickCumulatives[1] - tickCumulatives[0]) /
                    int56(uint56(gelatoSlippageInterval))
            );
            avgSqrtRatioX96 = avgTick.getSqrtRatioAtTick();
        }

        uint160 maxSlippage = (avgSqrtRatioX96 * gelatoSlippageBPS) / 10000;
        if (zeroForOne) {
            require(
                swapThresholdPrice >= avgSqrtRatioX96 - maxSlippage,
                "high slippage"
            );
        } else {
            require(
                swapThresholdPrice <= avgSqrtRatioX96 + maxSlippage,
                "high slippage"
            );
        }
    }
}
