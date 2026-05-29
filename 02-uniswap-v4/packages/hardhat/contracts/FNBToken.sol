// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNBToken provides an ERC20 token instance for the Uniswap v4 assignment.
contract FNBToken is ERC20 {
    // Deploy the token and assign the initial supply to the deployer.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}
