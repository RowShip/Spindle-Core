// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;
import {OwnableUninitialized} from "./OwnableUninitialized.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { SpindleFactoryStorage } from "./SpindleFactoryStorage.sol";
import {ISpindleOracle} from "../interfaces/ISpindleOracle.sol";
import {TickMath} from "../libraries/TickMath.sol";

import "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

// Implement packed slot and load packed slot to store a variety of key parameters used frequently in the vault's code, stored in a single slot to save gas
// Implement Uniswap library to further save on gas

/// @dev Single Global upgradeable state var storage base: APPEND ONLY
/// @dev Add all inherited contracts with state vars here: APPEND ONLY
/// @dev ERC20Upgradable Includes Initialize
// solhint-disable-next-line max-states-count
abstract contract SpindleVaultStorage is
    ERC20Upgradeable, /* XXXX DONT MODIFY ORDERING XXXX */
    OwnableUninitialized
    // APPEND ADDITIONAL BASE WITH STATE VARS BELOW:
    // XXXX DONT MODIFY ORDERING XXXX
{
    // solhint-disable-next-line const-name-snakecase
    string public constant version = "1.0.0";
    // solhint-disable-next-line const-name-snakecase

    // XXXXXXXX DO NOT MODIFY ORDERING XXXXXXXX

    uint16 public reinvestBPS; /// @dev percent of fees sent to caller of reinvest()
    uint24 public minTickThreshold; /// @dev min tick delta for initiating recenter 
    uint24 public tickThreshold; /// @dev tick delta to trigger a recenter
    uint16 public ivThresholdBPS; /// @dev implied volatility percentage change to trigger a recenter
    uint32 public timeThreshold; /// @dev time difference to trigger a recenter
   
    int24 public tickAtLastRecenter; /// @dev tick when last recenter executed
    uint256 public ivAtLastRecenter; /// @dev implied volatility when last recenter executed
    uint256 public timeAtLastRecenter; /// @dev timestamp when last recenter executed

    uint16 public managerFeeBPS;
    address public managerTreasury;

    uint256 public managerBalance0;
    uint256 public managerBalance1;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;

    int24 public TICK_SPACING;
    int24 public constant MIN_WIDTH = 402; 
    int24 public constant MAX_WIDTH = 27728; 
    int24 public MIN_TICK;
    int24 public MAX_TICK;

    uint16 public constant MAX_PRICE_MULTIPLIER_BPS = 10500; /// @dev Price multiplier of 1.05 at the start of recenter dutch auction
    uint16 public constant MIN_PRICE_MULTIPLIER_BPS = 9500; /// @dev Price multiplier of 0.95 at the end of recenter dutch auction
    uint16 public constant AUCTION_TIME = 600; /// @dev 10 minute duration for recenter dutch auctions.
    uint32 public constant TWAP_PERIOD = 180 seconds; /// @dev twap period to use for price based recenter calculations

    /// @dev \frac{1e18}{B} (1 - \frac{1}{1.0001^(MIN_WIDTH / 2})
    uint64 public A;

    /// @dev B = 2*sqrt(7)*10_000 
    uint16 public B; // Liquidity position should cover 95% (2 std. dev.) of trading activity over a 7 day period

    /// @dev \frac{1e18}{B} (1 - \frac{1}{1.0001^(MAX_WIDTH / 2})
    uint64 public C;

    ISpindleOracle public SpindleOracle;

    struct PackedSlot {
        // The primary position's lower tick bound
        int24 primaryLower;
        // The primary position's upper tick bound
        int24 primaryUpper;
        // The limit order's lower tick bound
        int24 limitLower;
        // The limit order's upper tick bound
        int24 limitUpper;
        // Whether the vault is currently locked to reentrancy
        bool locked;
    }

    PackedSlot public packedSlot;

    // APPPEND ADDITIONAL STATE VARS BELOW:
    // XXXXXXXX DO NOT MODIFY ORDERING XXXXXXXX

    event UpdateManagerParams(
        uint16 managerFeeBPS,
        address managerTreasury,
        uint16 reinvestBPS,
        uint24 minTickThreshold,
        uint24 tickThreshold,
        uint16 ivThresholdBPS,
        uint32 timeThreshold,
        uint16 stdBPS
    );

    /// @notice initialize storage variables on a new SS-UNI pool, only called once
    /// @param _name name of SS-UNI token
    /// @param _symbol symbol of SS-UNI token
    /// @param _pool address of Uniswap V3 pool
    /// note that the 4 above params are NOT UPDATEABLE AFTER INILIALIZATION
    /// @param _lowerTick initial lowerTick (only changeable with executiveRebalance)
    /// @param _upperTick initial upperTick (only changeable with executiveRebalance)
    /// @param _manager_ address of manager (ownership can be transferred)
    function initialize(
        string memory _name,
        string memory _symbol,
        address _pool,
        uint16 _managerFeeBPS,
        int24 _lowerTick,
        int24 _upperTick,
        address _manager_
    ) external initializer {

        // these variables are immutable after initialization
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        TICK_SPACING = pool.tickSpacing();
        MIN_TICK = TickMath.ceil(TickMath.MIN_TICK, TICK_SPACING);
        MAX_TICK = TickMath.floor(TickMath.MAX_TICK, TICK_SPACING);
        SpindleOracle = SpindleFactoryStorage(msg.sender).SpindleOracle();
        // these variables can be udpated by the manager
        reinvestBPS = 200; // default: only rebalance if tx fee is lt 2% reinvested
        managerFeeBPS = _managerFeeBPS;
        managerTreasury = _manager_; // default: treasury is admin
        packedSlot.primaryLower = _lowerTick;
        packedSlot.primaryUpper = _upperTick;
        _manager = _manager_;

        // e.g. "Swap Sweep Uniswap V3 USDC/DAI LP" and "SS-UNI"
        __ERC20_init(_name, _symbol);
    }

    /// @notice change configurable strategy parameters, only manager can call
    // solhint-disable-next-line code-complexity
    function updateManagerParams(
        int16 newManagerFeeBPS,
        address newManagerTreasury,
        int16 newReinvestBPS,
        int24 newMinTickThreshold,
        int24 newTickThreshold,
        int16 newIVThresholdBPS,
        int32 newTimeThreshold,
        int16 newStdBPS /// @dev standard deviations of trading activity primary liquidity positions should cover over recenterTimeThreshold
    ) external onlyManager {
        require(newReinvestBPS <= 10000, "BPS");
        require(newManagerFeeBPS <= 10000, "BPS");
        if (newManagerFeeBPS >= 0) managerFeeBPS = uint16(newManagerFeeBPS);
        if (address(0) != newManagerTreasury)
            managerTreasury = newManagerTreasury;
        if (newReinvestBPS >= 0) reinvestBPS = uint16(newReinvestBPS);
        if (newMinTickThreshold >= 0)
            minTickThreshold = uint24(newMinTickThreshold);
        if (newTickThreshold >= 0) tickThreshold = uint24(newTickThreshold);
        if (newIVThresholdBPS >= 0) ivThresholdBPS = uint16(newIVThresholdBPS);
        if (newTimeThreshold >= 0) timeThreshold = uint32(newTimeThreshold);
        if (newStdBPS >= 0 && newTimeThreshold >= 0) {
            B = uint16(
                (uint16(newStdBPS)*
                FixedPointMathLib.sqrt(uint32(newTimeThreshold)))/2940000 
            ); // 2940000 = sqrt(seconds in a day)*10_000
            A = uint64(
                1e18/B*(1-FixedPointMathLib.rpow(10001, uint24(MIN_WIDTH/2), 1))
            );// \frac{1e18}{B} (1 - \frac{1}{1.0001^(MIN_WIDTH / 2)})
            C = uint64(
                1e18/B*(1-FixedPointMathLib.rpow(10001, uint24(MAX_WIDTH/2), 1))
            );// \frac{1e18}{B} (1 - \frac{1}{1.0001^(MAX_WIDTH / 2)})
            
        }
        require(managerFeeBPS + reinvestBPS <= 10000, "BPS");
        emit UpdateManagerParams(
            managerFeeBPS,
            managerTreasury,
            reinvestBPS,
            minTickThreshold,
            tickThreshold,
            ivThresholdBPS,
            timeThreshold,
            uint16(newStdBPS)
        );
    }

    function renounceOwnership() public virtual override onlyManager {
        managerTreasury = address(0);
        managerFeeBPS = 0;
        managerBalance0 = 0;
        managerBalance1 = 0;
        super.renounceOwnership();
    }

}
