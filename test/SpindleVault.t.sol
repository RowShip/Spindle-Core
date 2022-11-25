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

contract SpindleVaultTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    SwapTest public swapTest;
    IUniswapV3Pool public uniPool;
    SpindleOracle public spindleOracle;
    SpindleVault public spindleVault;
    SpindleFactory public spindleFactory;
    Utils internal utils;
    address payable[] internal users;
    
    function setUp() public {
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

    function test_deposit() public {
        token0.approve(
            address(spindleVault),
            1000000 ether
        );
        token1.approve(
            address(spindleVault),
            1000000 ether
        );
        _mint(1 ether, 1 ether);
        assertGt(token0.balanceOf(address(uniPool)), 0);
        assertGt(token1.balanceOf(address(uniPool)), 0);

        uint128 liquidity;
        (liquidity, , , , ) = uniPool.positions(
            _getPositionID(address(spindleVault), -887220, 887220)
        );
        assertGt(liquidity, 0);
        assertGt(spindleVault.totalSupply(), 0);
        _mint(0.5 ether, 1 ether);
        uint128 liquidity2;
        (liquidity2, , , , ) = uniPool.positions(
            _getPositionID(address(spindleVault), -887220, 887220)
        );
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
}
