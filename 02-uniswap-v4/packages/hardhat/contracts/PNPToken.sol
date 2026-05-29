// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PNPToken provides the second ERC20 token used in the Uniswap v4 assignment.
contract PNPToken is ERC20 {
    // Deploy the token and allocate the initial supply to the deployer.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}
