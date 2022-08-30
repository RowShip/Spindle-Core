//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3TickSpacing} from "./interfaces/IUniswapV3TickSpacing.sol";
import {ISSUniFactory} from "./interfaces/ISSUniFactory.sol";
import {ISSUniVaultStorage} from "./interfaces/ISSUniVaultStorage.sol";
import {SSUniFactoryStorage} from "./abstract/SSUniFactoryStorage.sol";
import {EIP173Proxy} from "./proxy/EIP173Proxy.sol";
import {IEIP173Proxy} from "./interfaces/IEIP173Proxy.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";

contract SSUniFactory is SSUniFactoryStorage, ISSUniFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(address _uniswapV3Factory, IVolatilityOracle _volatilityOracle)
        SSUniFactoryStorage(_uniswapV3Factory, _volatilityOracle)
    {} // solhint-disable-line no-empty-blocks

    /// @notice createManagedPool creates a new instance of a SS-UNI token on a specified
    /// UniswapV3Pool. The msg.sender is the initial manager of the pool and will
    /// forever be associated with the SS-UNI pool as it's `deployer`
    /// @param tokenA one of the tokens in the uniswap pair
    /// @param tokenB the other token in the uniswap pair
    /// @param uniFee fee tier of the uniswap pair
    /// @param managerFee proportion of earned fees that go to pool manager in Basis Points
    /// @param lowerTick initial lower bound of the Uniswap V3 position
    /// @param upperTick initial upper bound of the Uniswap V3 position
    /// @return pool the address of the newly created SS-UNI pool (proxy)
    function createManagedPool(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint16 managerFee,
        int24 lowerTick,
        int24 upperTick
    ) external override returns (address pool) {
        return
            _createPool(
                tokenA,
                tokenB,
                uniFee,
                managerFee,
                lowerTick,
                upperTick,
                msg.sender
            );
    }

    /// @notice createPool creates a new instance of a SS-UNI token on a specified
    /// UniswapV3Pool. Here the manager role is immediately burned, however msg.sender will still
    /// forever be associated with the SS-UNI pool as it's `deployer`
    /// @param tokenA one of the tokens in the uniswap pair
    /// @param tokenB the other token in the uniswap pair
    /// @param uniFee fee tier of the uniswap pair
    /// @param lowerTick initial lower bound of the Uniswap V3 position
    /// @param upperTick initial upper bound of the Uniswap V3 position
    /// @return pool the address of the newly created SS-UNI pool (proxy)
    function createPool(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        int24 lowerTick,
        int24 upperTick
    ) external override returns (address pool) {
        return
            _createPool(
                tokenA,
                tokenB,
                uniFee,
                0,
                lowerTick,
                upperTick,
                address(0)
            );
    }

    function _createPool(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint16 managerFee,
        int24 lowerTick,
        int24 upperTick,
        address manager
    ) internal returns (address pool) {
        (address token0, address token1) = _getTokenOrder(tokenA, tokenB);

        pool = address(new EIP173Proxy(poolImplementation, address(this), ""));

        string memory name = "SwapSweep Uniswap Vault";
        try this.getTokenName(token0, token1) returns (string memory result) {
            name = result;
        } catch {} // solhint-disable-line no-empty-blocks

        address uniPool =
            IUniswapV3Factory(factory).getPool(token0, token1, uniFee);
        require(uniPool != address(0), "uniswap pool does not exist");
        require(
            _validateTickSpacing(uniPool, lowerTick, upperTick),
            "tickSpacing mismatch"
        );

        ISSUniVaultStorage(pool).initialize(
            name,
            "SS-UNI",
            uniPool,
            managerFee,
            lowerTick,
            upperTick,
            manager
        );
        _deployers.add(msg.sender);
        _pools[msg.sender].add(pool);
        emit PoolCreated(uniPool, manager, pool);
    }

    function _validateTickSpacing(
        address uniPool,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (bool) {
        int24 spacing = IUniswapV3TickSpacing(uniPool).tickSpacing();
        return
            lowerTick < upperTick &&
            lowerTick % spacing == 0 &&
            upperTick % spacing == 0;
    }

    function getTokenName(address token0, address token1)
        external
        view
        returns (string memory)
    {
        string memory symbol0 = IERC20Metadata(token0).symbol();
        string memory symbol1 = IERC20Metadata(token1).symbol();

        return _append("SwapSweep Uniswap ", symbol0, "/", symbol1, " Vault");
    }

    function upgradePools(address[] memory pools) external onlyManager {
        for (uint256 i = 0; i < pools.length; i++) {
            IEIP173Proxy(pools[i]).upgradeTo(poolImplementation);
        }
    }

    function upgradePoolsAndCall(address[] memory pools, bytes[] calldata datas)
        external
        onlyManager
    {
        require(pools.length == datas.length, "mismatching array length");
        for (uint256 i = 0; i < pools.length; i++) {
            IEIP173Proxy(pools[i]).upgradeToAndCall(
                poolImplementation,
                datas[i]
            );
        }
    }

    function makePoolsImmutable(address[] memory pools) external onlyManager {
        for (uint256 i = 0; i < pools.length; i++) {
            IEIP173Proxy(pools[i]).transferProxyAdmin(address(0));
        }
    }

    /// @notice isPoolImmutable checks if a certain SS-UNI pool is "immutable" i.e. that the
    /// proxyAdmin is the zero address and thus the underlying implementation cannot be upgraded
    /// @param pool address of the SS-UNI pool
    /// @return bool signaling if pool is immutable (true) or not (false)
    function isPoolImmutable(address pool) external view returns (bool) {
        return address(0) == getProxyAdmin(pool);
    }

    /// @notice getDeployers fetches all addresses that have deployed a SS-UNI pool
    /// @return deployers the list of deployer addresses
    function getDeployers() public view returns (address[] memory) {
        uint256 length = numDeployers();
        address[] memory deployers = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            deployers[i] = _getDeployer(i);
        }

        return deployers;
    }

    /// @notice getPools fetches all the SS-UNI pool addresses deployed by `deployer`
    /// @param deployer address that has potentially deployed SS-UNI pools (can return empty array)
    /// @return pools the list of SS-UNI pool addresses deployed by `deployer`
    function getPools(address deployer) public view returns (address[] memory) {
        uint256 length = numPools(deployer);
        address[] memory pools = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            pools[i] = _getPool(deployer, i);
        }

        return pools;
    }

    /// @notice numPools counts the total number of SS-UNI pools in existence
    /// @return result total number of SS-UNI pools deployed
    function numPools() public view returns (uint256 result) {
        address[] memory deployers = getDeployers();
        for (uint256 i = 0; i < deployers.length; i++) {
            result += numPools(deployers[i]);
        }
    }

    /// @notice numDeployers counts the total number of SS-UNI pool deployer addresses
    /// @return total number of SS-UNI pool deployer addresses
    function numDeployers() public view returns (uint256) {
        return _deployers.length();
    }

    /// @notice numPools counts the total number of SS-UNI pools deployed by `deployer`
    /// @param deployer deployer address
    /// @return total number of SS-UNI pools deployed by `deployer`
    function numPools(address deployer) public view returns (uint256) {
        return _pools[deployer].length();
    }

    /// @notice getProxyAdmin gets the current address who controls the underlying implementation
    /// of a SS-UNI pool. For most all pools either this contract address or the zero address will
    /// be the proxyAdmin. If the admin is the zero address the pool's implementation is naturally
    /// no longer upgradable (no one owns the zero address).
    /// @param pool address of the SS-UNI pool
    /// @return address that controls the SS-UNI implementation (has power to upgrade it)
    function getProxyAdmin(address pool) public view returns (address) {
        return IEIP173Proxy(pool).proxyAdmin();
    }

    function _getDeployer(uint256 index) internal view returns (address) {
        return _deployers.at(index);
    }

    function _getPool(address deployer, uint256 index)
        internal
        view
        returns (address)
    {
        return _pools[deployer].at(index);
    }

    function _getTokenOrder(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "same token");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "no address zero");
    }

    function _append(
        string memory a,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c, d, e));
    }
}
