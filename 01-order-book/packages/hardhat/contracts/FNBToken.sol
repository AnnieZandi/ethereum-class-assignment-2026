// contracts/FNBToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNBToken uses OpenZeppelin's ERC20 implementation so the token follows the standard ERC20 interface.
contract FNBToken is ERC20 {
    // The constructor sets the token metadata and allocates the initial supply to the deployer.
    // `initialSupply` is the total number of tokens minted at deployment.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint the starting balance directly to the account that deploys the contract.
        _mint(msg.sender, initialSupply);
    }
}
