// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {XWalletRegistry} from "../src/XWalletRegistry.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {SponsorPaymaster} from "../src/SponsorPaymaster.sol";
import {SmartAccountFactory} from "../src/SmartAccountFactory.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @author gnvvs-2003
 * @title DeployAll
 * @notice Deploys the complete Project in this order
 * 1. XWalletRegistry
 * 2. SmartAccountFactory => including SmartAccount
 * 3. SponsorPaymaster
 * 4. Funds the user for gas costs by the paymaster
 * @custom:entryPoint Sepolia official entry point addr : `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789`
 */

contract DeployAll is Script {
    // ══════════════════════════════════════════════════════
    //                    STATE VARIABLES
    // ══════════════════════════════════════════════════════
    address constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 constant MAX_GAS_PER_OP = 0.005 ether;
    uint256 constant MAX_GAS_PER_USER = 0.05 ether;
    uint256 constant INITIAL_PAYMASTER_FUND = 0.1 ether;

    // ══════════════════════════════════════════════════════
    //                    RUN FUNCTION
    // ══════════════════════════════════════════════════════
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 paymasterPrivateKey = vm.envUint("PAYMASTER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address paymasterSigner = vm.addr(paymasterPrivateKey);
        address backendSigner = vm.envAddress(BACKEND_SIGNER_ADDRESS);
        console2.log(":) DEPLOYING X WALLET SYSTEM (:");
        console2.log(">>>DETAILS<<<");
        console2.log("Deployer                       :", deployer);
        console2.log("Paymaster Signer               :", paymasterSigner);
        console2.log("Backend Signer                 :", backendSigner);
        console2.log("Entry point                    :", entryPoint);
        console2.log("---------------Broadcasting--------------");
        vm.startBroadcast(deployerPrivateKey);
        /// @dev Step-1 : Deploy XWalletRegistry
        console2.log("-------Step-1 : Deploying Registry--------");
        XWalletRegistry registry = new XWalletRegistry(backendSigner);
        console2.log("Registry Deployed at           :", address(registry));
        /// @dev Step-2 : Deploy SmartAccountFactory (including SmartAccount)
        console2.log("--Step-2 : Deploying SmartAccount Factory---");
        SmartAccountFactory factory = new SmartAccountFactory(IEntryPoint(ENTRY_POINT));
        console2.log("Factory Deployed at            :", address(factory));
        console2.log("SmartAccount Deployed at       :", address(factory.accountImplementation()));
        /// @dev Step-3 : Deploy SponsorPaymaster
        console2.log("-------Step-3 : Deploying Paymaster--------");
        /**
         * @custom:code
         *     constructor(
         *         IEntryPoint _entryPoint, => entryPoint:fixed sepolia ENTRY_POINT
         *         address _paymasterSigner, => paymasterSigner
         *         address _registry, => registry from XWalletRegistry => address
         *         uint256 _maxGasCostPerOperation, => 0.005 ether(fixed MAX_GAS_PER_OP)
         *         uint256 _maxPerUser => 0.05 ether(fixed MAX_GAS_PER_USER)
         *     )
         */
        SponsorPaymaster paymaster = new SponsorPaymaster(
            IEntryPoint(ENTRY_POINT), paymasterSigner, address(registry), MAX_GAS_PER_OP, MAX_GAS_PER_USER
        );
        console2.log("Registry Deployed at           :", address(registry));
        /// @dev Step-4 : Funding Paymaster
        /// @notice Paymaster needs ETH deposited in the EntryPoint to pay gas fee
        console2.log("--------FUNDING PAYMASTER WITH 0.1 ETH-------");
        paymaster.depositFunds{value: INITIAL_PAYMASTER_FUND}();
        console2.log("Paymaster balance              :", paymaster.getDeposit());
        /// @dev complete deployment
        vm.stopBroadcast();
        /// ══════════════════════════ DEPLOYMENT DETAILS ══════════════════════════
        console2.log("           -DEPLOYMENT DETAILS-          ");
        console2.log("XWalletRegistry                :", address(registry));
        console2.log("SmartAccountFactory            :", address(factory));
        console2.log("SponsorPaymaster               :", address(paymaster));
        console2.log("EntryPoint sepolia             :", ENTRY_POINT);
        /// ══════════════════ DEPLOYMENT DETAILS SAVING IN FILE ══════════════════
        string memory envContent = string(
            abi.encodePacked(
                "REGISTRY_ADDRESS=",
                vm.toString(address(registry)),
                "\n",
                "FACTORY_ADDRESS=",
                vm.toString(address(factory)),
                "\n",
                "PAYMASTER_ADDRESS=",
                vm.toString(address(paymaster)),
                "\n",
                "ENTRY_POINT",
                vm.toString(ENTRY_POINT),
                "\n"
            )
        );
        vm.createDir("deployments", true);
        vm.writeFile("deployments/sepolia.env", envContent);
        console2.log("Deployment Details saved to    : [deployments/sepolia.env]");
    }
}
