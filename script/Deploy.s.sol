// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DemoToken} from "../src/DemoToken.sol";
import {SignedVault} from "../src/SignedVault.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        DemoToken token = new DemoToken();
        SignedVault vaultA = new SignedVault(token);
        SignedVault vaultB = new SignedVault(token);

        vm.stopBroadcast();

        console.log("DemoToken:", address(token));
        console.log("SignedVault A:", address(vaultA));
        console.log("SignedVault B:", address(vaultB));
    }
}
