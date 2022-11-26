// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;
import "forge-std/Test.sol";
import "../src/SpindleFactory.sol";
import "../src/SpindleVault.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../src/SpindleOracle.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/SwapTest.sol";
import "../src/libraries/TickMath.sol";
import "./UniFactoryByteCode.sol";
import "./Utils.t.sol";
import {LiquidityAmounts} from "../src/libraries/FullMath.sol";


contract SpindleVaultTestBase is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    SwapTest public swapTest;
    IUniswapV3Pool public uniPool;
    SpindleOracle public spindleOracle;
    SpindleVault public spindleVault;
    SpindleFactory public spindleFactory;
    Utils internal utils;
    address payable[] internal users;
    
    function setUp() public virtual {
        // deploy utils contract and create users
        utils = new Utils();
        users = utils.createUsers(5);
        // deploy mock erc20 and swap test
        token0 = new MockERC20();
        token1 = new MockERC20();
        swapTest = new SwapTest();
        // approve swap test to spend mocks tokens
        token0.approve(address(swapTest), type(uint256).max);
        token1.approve(address(swapTest), type(uint256).max);
        // deploy mock uniswap v3 factory
        address factory = _deploy(UNI_FACTORY_CREATION_CODE);
        // Sort token0 & token1 so it follows the same order as Uniswap & the SpindleVaultFactory
        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        // Create UniV3 pool with mock tokens for fee tier 0.3%
        (bool success, bytes memory data) = factory.call(abi.encodeWithSignature(
            "createPool(address,address,uint24)", address(token0), address(token1), 3000));
        uniPool = abi.decode(data, (IUniswapV3Pool));
        require(success, "failed");
        uniPool.initialize(TickMath.getSqrtRatioAtTick(0));
        uniPool.increaseObservationCardinalityNext(15);
        // Deploy spindle oracle, factory and vault.
        spindleOracle = new SpindleOracle();
        spindleFactory = new SpindleFactory(address(factory), spindleOracle);
        // Deploy implementation contract for spindle Vault
        // and then pass the address for it to initialize the factory, setting the manager as this address
        spindleFactory.initialize(address(new SpindleVault()), address(this));
        spindleVault = SpindleVault(spindleFactory.deployVault(
            address(token0),
            address(token1),
            3000,
            address(this),
            0,
            -887220,
            887220
        ));

    }
    function _deploy(bytes memory _code) internal returns (address addr) {
        assembly {
            // create(v, p, n)
            // v = amount of ETH to send
            // p = pointer in memory to start of code
            // n = size of code
            addr := create(callvalue(), add(_code, 0x20), mload(_code))
        }
        // return address 0 on error
        require(addr != address(0), "deploy failed");
    }

    function _mint(uint256 amount0 , uint256 amount1) internal {
        (, , uint256 mintAmount) = spindleVault.getMintAmounts(amount0, amount1);
        spindleVault.mint(mintAmount, address(this));
    }
    function _getPositionID(address addr, int24 lowerTick, int24 upperTick) internal pure returns (bytes32 positionID) {
        return keccak256(abi.encodePacked(addr, lowerTick, upperTick));
    }

    function _info(address addr, int24 lower, int24 upper)
        internal
        view
        returns (
            uint128, // liquidity
            uint256, // feeGrowthInside0LastX128
            uint256, // feeGrowthInside1LastX128
            uint128, // tokensOwed0
            uint128 // tokensOwed1
        )
    {
        return uniPool.positions(keccak256(abi.encodePacked(addr, lower, upper)));
    }
    function _liquidityForAmountsCheck(
        int24 lower,
        int24 upper,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128, bool) {
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(lower),
                TickMath.getSqrtRatioAtTick(upper),
                amount0,
                amount1
            );
    }

    function _washTrades() internal {
        swapTest.washTrade(
            address(uniPool),
            50000000000000,
            100,
            2
          );
        swapTest.washTrade(
            address(uniPool),
            50000000000000,
            100,
            3
          );
        swapTest.washTrade(
            address(uniPool),
            50000000000000,
            100,
            3
          );
        swapTest.washTrade(
            address(uniPool),
            50000000000000,
            100,
            3
          );
    }
}

contract SpindleVaultTest is SpindleVaultTestBase {
    function setUp() public override virtual {
        super.setUp();
        token0.approve(
            address(spindleVault),
            1000000 ether
        );
        token1.approve(
            address(spindleVault),
            1000000 ether
        );
        _mint(1 ether, 1 ether);
    }
    function test_deposit() public {
        // FAIL CASE
        vm.expectRevert(abi.encodePacked("mint 0"));
        spindleVault.mint(0, address(this));

        // SUCCESS CASE
        console.log("Should deposit liquidity into spindle vault");

        assertGt(token0.balanceOf(address(uniPool)), 0);
        assertGt(token1.balanceOf(address(uniPool)), 0);

        uint128 liquidity;
        (liquidity, , , , ) = _info(address(spindleVault), -887220, 887220);
        assertGt(liquidity, 0);
        assertGt(spindleVault.totalSupply(), 0);
        _mint(0.5 ether, 1 ether);

        uint128 liquidity2;
        (liquidity2, , , , ) = _info(address(spindleVault), -887220, 887220);
        assertGt(liquidity2, liquidity);

        spindleVault.transfer(users[0], 1 ether);
        vm.prank(users[0]);
        spindleVault.approve(address(this), 1 ether);
        vm.prank(address(this));
        spindleVault.transferFrom(users[0], address(this), 1 ether);

        assertEq(spindleVault.decimals(), 18);
        assertEq(spindleVault.symbol(), "SPV 1");
        assertEq(spindleVault.name(), "Spindle Vault V1 TOKEN/TOKEN");
    }

    function test_withdraw () public {
        // FAIL CASE
        vm.expectRevert(abi.encodePacked("burn 0"));
        spindleVault.burn(0, address(this));

        console.log("Should withdraw liquidity from spindle vault");

        spindleVault.burn(spindleVault.totalSupply()/2, address(this));

        uint128 liquidity;
        (liquidity, , , , ) = _info(address(spindleVault), -887220, 887220);
        assertGt(liquidity, 0);
        assertGt(spindleVault.totalSupply(), 0);
        assertEq(spindleVault.balanceOf(address(this)), 0.5 ether);
    }

    function test_reinvest () public {
        // FAIL CASE
        vm.expectRevert(abi.encodePacked("liquidity must increase"));
        spindleVault.reinvest();

        console.log("Should redeposit fees with a reinvest call");

        _washTrades();

        uint128 liquidityOld;
        uint256 a;
        uint256 b;

        // poke liquidity positionin vault by calling getUnderlyingBalances so fees are updated
        spindleVault.getUnderlyingBalances();
        (liquidityOld, , , a, b) = _info(address(spindleVault), -887220, 887220);

        // get token balances before calling reinvest
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        spindleVault.reinvest();

        //Make sure manager balance was updated correctly
        uint16 feeBPS = spindleVault.managerFeeBPS();
        console.log("expected", spindleVault.managerBalance0());
        console.log("actual", feeBPS*a/10000);
        assertEq(spindleVault.managerBalance0(), feeBPS*a/10000);
        assertEq(spindleVault.managerBalance1(), feeBPS*b/10000);

        // Make sure keeper rewards were paid out correctly
        feeBPS = spindleVault.reinvestBPS();
        assertEq(token0.balanceOf(address(this)) - balance0Before, feeBPS*a/10000);
        assertEq(token1.balanceOf(address(this)) - balance1Before, feeBPS*b/10000);

        // Check to ensure liquidity increased
        uint128 liquidityNew;
        (liquidityNew, , , , ) = _info(address(spindleVault),-887220, 887220);
        assertGt(liquidityNew, liquidityOld);

        // Check to ensure limit order was placed correctly
        (uint160 sqrtRatioX96, int24 tick, , , , , ) = uniPool.slot0();
        (, bool limitedBy0) = _liquidityForAmountsCheck(
            -887220, 
            887220,
            sqrtRatioX96,
            a - (spindleVault.managerFeeBPS() + spindleVault.reinvestBPS())*a/10000,
            b - (spindleVault.managerFeeBPS() + spindleVault.reinvestBPS())*b/10000
        );

        (,, int24 lower, int24 upper,) = spindleVault.packedSlot();
        if(limitedBy0) {
            assertEq(lower, TickMath.floor(tick, uniPool.tickSpacing()) - uniPool.tickSpacing());
            assertEq(upper, TickMath.floor(tick, uniPool.tickSpacing()));
        } else {
            assertEq(lower, TickMath.ceil(tick, uniPool.tickSpacing()));
            assertEq(upper, TickMath.ceil(tick, uniPool.tickSpacing()) + uniPool.tickSpacing());
        }
    }
    

}
