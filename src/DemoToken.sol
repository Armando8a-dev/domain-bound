// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC20 used only to fund both vaults for the demo.
contract DemoToken is ERC20 {
    constructor() ERC20("Demo Token", "DEMO") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
