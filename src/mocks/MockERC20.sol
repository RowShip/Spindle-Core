// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract MockERC20 is ERC20Upgradeable {

    constructor() {
        _initialize("", "TOKEN");
    }

    function _initialize(string memory _name, string memory _symbol) public initializer {
        __ERC20_init(_name, _symbol);
        _mint(msg.sender, 100000e18);
    }
}
