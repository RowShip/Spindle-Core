// SPDX-License-Identifier: MIT
import "./SSUniVault.sol";
pragma solidity ^0.8.10;

contract Resolver {
    SSUniVault public immutable SWAP_SWEEP;

    constructor(address _swapSweep) {
        SWAP_SWEEP = SSUniVault(_swapSweep);
    }

    // function checkCanRebalance(uint256 _deadline)
    //     external
    //     view
    //     returns (bool canExec, bytes memory execPayload)
    // {
    //     // solhint-disable not-rely-on-time
    //     canExec = SWAP_SWEEP.canRebalance();

    //     _deadline = block.timestamp + _deadline;
    //     execPayload = abi.encodeWithSelector(
    //         SWAP_SWEEP.rebalance.selector,
    //         _deadline
    //     );
    // }

    // function checkCanReposition()
    //     external
    //     view
    //     returns (bool canExec, bytes memory execPayload)
    // {
    //     // solhint-disable not-rely-on-time
    //     canExec = SWAP_SWEEP.canReposition();

    //     execPayload = abi.encodeWithSignature("reposition()");
    // }
}