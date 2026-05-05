// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {XWalletRegistry} from "../src/XWalletRegistry.sol";
import {SponsorPaymaster} from "../src/SponsorPaymaster.sol";
import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";

contract SponsorPaymasterTest is Test {
    EntryPoint public entryPoint;
    XWalletRegistry public registry;
    SponsorPaymaster public paymaster;
    uint256 paymasterSignerPrivateKey = 0xABCDEF;
    address paymasterSignerAddress;
    address deployer = makeAddr("deployer");
}
