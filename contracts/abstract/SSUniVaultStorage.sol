// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {Gelatofied} from "./Gelatofied.sol";
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

import { SSUniFactoryStorage } from "./SSUniFactoryStorage.sol";
import {IVolatilityOracle} from "../interfaces/IVolatilityOracle.sol";
import {TickMath} from "../libraries/TickMath.sol";

// Implement packed slot and load packed slot to store a variety of key parameters used frequently in the vault's code, stored in a single slot to save gas
// Implement Uniswap library to further save on gas

/// @dev Single Global upgradeable state var storage base: APPEND ONLY
/// @dev Add all inherited contracts with state vars here: APPEND ONLY
/// @dev ERC20Upgradable Includes Initialize
// solhint-disable-next-line max-states-count
abstract contract SSUniVaultStorage is
    ERC20Upgradeable, /* XXXX DONT MODIFY ORDERING XXXX */
    ReentrancyGuardUpgradeable,
    OwnableUninitialized,
    Gelatofied
    // APPEND ADDITIONAL BASE WITH STATE VARS BELOW:
    // XXXX DONT MODIFY ORDERING XXXX
{
    // solhint-disable-next-line const-name-snakecase
    string public constant version = "1.0.0";
    // solhint-disable-next-line const-name-snakecase

    // XXXXXXXX DO NOT MODIFY ORDERING XXXXXXXX

    uint16 public gelatoRebalanceBPS;
    uint16 public gelatoSlippageBPS;
    uint32 public gelatoSlippageInterval;

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

    /// @dev B = 2*sqrt(7)*10_000 
    uint16 public constant B = 5.2915e4; // Liquidity position should cover 95% (2 std. dev.) of trading activity over a 7 day period
    IVolatilityOracle public volatilityOracle;

    struct PackedSlot {
        // The primary position's lower tick bound
        int24 primaryLower;
        // The primary position's upper tick bound
        int24 primaryUpper;
        // The limit order's lower tick bound
        int24 limitLower;
        // The limit order's upper tick bound
        int24 limitUpper;
    }

    PackedSlot public packedSlot;

    // APPPEND ADDITIONAL STATE VARS BELOW:
    // XXXXXXXX DO NOT MODIFY ORDERING XXXXXXXX

    event UpdateGelatoParams(
        uint16 gelatoRebalanceBPS,
        uint16 gelatoWithdrawBPS,
        uint16 gelatoSlippageBPS,
        uint32 gelatoSlippageInterval
    );

    event SetManagerFee(uint16 managerFee);

    // solhint-disable-next-line max-line-length
    constructor(address payable _gelato) Gelatofied(_gelato) {} // solhint-disable-line no-empty-blocks

    /// @notice initialize storage variables on a new SS-UNI pool, only called once
    /// @param _name name of SS-UNI token
    /// @param _symbol symbol of SS-UNI token
    /// @param _pool address of Uniswap V3 pool
    /// @param _managerFeeBPS proportion of fees earned that go to manager treasury
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
        managerFeeBPS = _managerFeeBPS; // if set to 0 here manager can still initialize later
        volatilityOracle = SSUniFactoryStorage(msg.sender).volatilityOracle();
        // these variables can be udpated by the manager
        gelatoSlippageInterval = 5 minutes; // default: last five minutes;
        gelatoSlippageBPS = 500; // default: 5% slippage
        gelatoRebalanceBPS = 200; // default: only rebalance if tx fee is lt 2% reinvested
        managerTreasury = _manager_; // default: treasury is admin
        packedSlot.primaryLower = _lowerTick;
        packedSlot.primaryUpper = _upperTick;
        _manager = _manager_;

        // e.g. "Gelato Uniswap V3 USDC/DAI LP" and "SS-UNI"
        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();
    }

    /// @notice change configurable parameters, only manager can call
    /// @param newRebalanceBPS controls frequency of gelato rebalances: gas fee to execute
    /// rebalance can be gelatoRebalanceBPS proportion of fees earned since last rebalance
    /// @param newWithdrawBPS controls frequency of gelato withdrawals: gas fee to execute
    /// withdrawal can be gelatoWithdrawBPS proportion of fees accrued since last withdraw
    /// @param newSlippageBPS maximum slippage on swaps during gelato rebalance
    /// @param newSlippageInterval length of time for TWAP used in computing slippage on swaps
    /// @param newTreasury address where managerFee withdrawals are sent
    // solhint-disable-next-line code-complexity
    function updateGelatoParams(
        uint16 newRebalanceBPS,
        uint16 newWithdrawBPS,
        uint16 newSlippageBPS,
        uint32 newSlippageInterval,
        address newTreasury
    ) external onlyManager {
        require(newRebalanceBPS <= 10000, "BPS");
        require(newSlippageBPS <= 10000, "BPS");
        emit UpdateGelatoParams(
            newRebalanceBPS,
            newWithdrawBPS,
            newSlippageBPS,
            newSlippageInterval
        );
        if (newRebalanceBPS != 0) gelatoRebalanceBPS = newRebalanceBPS;
        if (newSlippageBPS != 0) gelatoSlippageBPS = newSlippageBPS;
        if (newSlippageInterval != 0)
            gelatoSlippageInterval = newSlippageInterval;
        if (newTreasury != address(0)) managerTreasury = newTreasury;
    }

    /// @notice initializeManagerFee sets a managerFee, only manager can call.
    /// If a manager fee was not set in the initialize function it can be set here
    /// but ONLY ONCE- after it is set to a non-zero value, managerFee can never be set again.
    /// @param _managerFeeBPS proportion of fees earned that are credited to manager in Basis Points
    function initializeManagerFee(uint16 _managerFeeBPS) external onlyManager {
        require(managerFeeBPS == 0, "fee");
        emit SetManagerFee(_managerFeeBPS);
        managerFeeBPS = _managerFeeBPS;
    }

    function renounceOwnership() public virtual override onlyManager {
        managerTreasury = address(0);
        managerFeeBPS = 0;
        managerBalance0 = 0;
        managerBalance1 = 0;
        super.renounceOwnership();
    }

}
