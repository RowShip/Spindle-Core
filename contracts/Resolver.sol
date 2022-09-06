// SPDX-License-Identifier: MIT
import "./SSUniVault.sol";
pragma solidity ^0.8.10;
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "./libraries/FixedPoint128.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";
contract Resolver {
    SSUniVault public immutable Vault;

    constructor(address _swapSweep) {
        Vault = SSUniVault(_swapSweep);
    }

    // function checkCanRebalance(uint256 _deadline)
    //     external
    //     view
    //     returns (bool canExec, bytes memory execPayload)
    // {
    //     // solhint-disable not-rely-on-time
    //     canExec = Vault.canRebalance();

    //     _deadline = block.timestamp + _deadline;
    //     execPayload = abi.encodeWithSelector(
    //         Vault.rebalance.selector,
    //         _deadline
    //     );
    // }
    // We need to check if we can reinvest or we need to recenter.
    // Fetch limit order data from vault to see one is open
    // Fetch fee data from primary Uni position on vault
    // and then check and see if the fee data > fee amount 
    // for the specified fee token. 
    // Need to inherit ops ready interface and then call
    // getFeeDetails on it to get the fee amount and fee Tokens
    // https://docs.gelato.network/developer-products/gelato-ops-smart-contract-automation-hub/paying-for-your-transactions
    // function checker()
    //     external
    //     view
    //     returns (bool canExec, bytes memory execPayload)
    // {
    //     // solhint-disable not-rely-on-time
    //     canExec = Vault.canReposition();

    //     execPayload = abi.encodeWithSignature("reposition()");
    // }
}