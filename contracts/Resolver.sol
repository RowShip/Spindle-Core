// SPDX-License-Identifier: MIT
import "./SSUniVault.sol";
pragma solidity ^0.8.4;

contract Resolver {

    // contract of SSNUniVault
    SSUniVault public immutable SWAP_SWEEP;

    constructor(address _swapSweep) {
        // Set execution contract address
        SWAP_SWEEP = SSUniVault(_swapSweep);
    }

    function checkCanRebalance(uint256 _deadline)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        // solhint-disable not-rely-on-time
        // set the Execution
        canExec = SWAP_SWEEP.canRebalance();

        // Reset tje payload
        execPayload = abi.encodeWithSelector(
            SWAP_SWEEP.rebalance.selector,
            block.timestamp + _deadline
        );
        return (canExec, execPayload);
    }

    function checkCanReposition()
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        // solhint-disable not-rely-on-time
        // set the Execution
        canExec = SWAP_SWEEP.canReposition();

        // Reset tje payload
        execPayload = abi.encodeWithSignature("reposition()");
        return (canExec, execPayload);

    }
}