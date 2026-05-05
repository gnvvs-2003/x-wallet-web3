// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {XWalletRegistry} from "../src/XWalletRegistry.sol";
import {console2} from "forge-std/console2.log";

/**
 * @author gnvvs-2003
 * @title DeployRegistry
 * @dev This contracts deploys XWalletRegistry using deployer PRIVATE KEY
 * @custom:run To run
 * @custom:command forge script script/DeployRegistry.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --vvvv
 */

contract DeployRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address backendSigner = vm.envAddress("BACKEND_SIGNER_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);
        console2.log("Deploying Registry!!!");
        XWalletRegistry registry = new XWalletRegistry(backendSigner);
        vm.stopBroadcast();
        string memory deploymentInfo = string(abi.encodePacked("REGISTRY_ADDRESS=", vm.toString(address(registry))));
        vm.writeFile("deployment/sepolia.env", deploymentInfo);
    }
}
