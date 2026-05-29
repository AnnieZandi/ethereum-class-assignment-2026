// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PNPToken provides the ERC20 token used for the assignment's second token example.
contract PNPToken is ERC20 {
    // Deploy the token and allocate the initial balance to the deployer.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}
