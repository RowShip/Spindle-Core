//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface ISpindleVault {
    event PoolCreated(
        address indexed uniPool,
        address indexed manager,
        address indexed pool
    );

    function deployVault(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        address manager,
        uint16 managerFee,
        int24 lowerTick,
        int24 upperTick
    ) external returns (address pool);
}
