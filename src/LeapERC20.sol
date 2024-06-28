// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import { ERC20 } from "solmate/tokens/ERC20.sol";

contract LeapERC20 is ERC20 {
    constructor(uint256 initialSupply, string memory _name, string memory _symbol) ERC20(_name, _symbol, 18) {
        _mint(msg.sender, initialSupply);
    }
}
