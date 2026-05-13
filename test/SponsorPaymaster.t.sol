// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XWalletRegistry} from "../src/XWalletRegistry.sol";
import {SponsorPaymaster} from "../src/SponsorPaymaster.sol";
import {EntryPoint} from "@account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

contract SponsorPaymasterTest is Test {
    // ══════════════════════════════════════════════════════
    //                    STATE VARIABLES
    // ══════════════════════════════════════════════════════
    IEntryPoint public entryPoint;
    XWalletRegistry public registry;
    SponsorPaymaster public paymaster;
    uint256 paymasterSignerPrivateKey = 0xABCDEF;
    address paymasterSignerAddress;
    address deployer = makeAddr("deployer");
    uint256 public constant MAX_GAS_COST_PER_OPERATION = 0.01 ether;
    uint256 public constant MAX_GAS_ALLOCATED_PER_USER = 0.1 ether;
    uint256 public constant TEST_DEPOSIT_FUND = 0.05 ether;

    // ══════════════════════════════════════════════════════
    //                         SETUP
    // ══════════════════════════════════════════════════════
    function setUp() public {
        paymasterSignerAddress = vm.addr(paymasterSignerPrivateKey);
        vm.startPrank(deployer);
        /// @notice Deploy contracts
        entryPoint = new EntryPoint();
        registry = new XWalletRegistry(makeAddr("backendSigner"));
        paymaster = new SponsorPaymaster(
            IEntryPoint(address(entryPoint)),
            paymasterSignerAddress,
            address(registry),
            MAX_GAS_COST_PER_OPERATION,
            MAX_GAS_ALLOCATED_PER_USER
        );
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //                        TEST FUNCTIONS
    // ══════════════════════════════════════════════════════
    function test_depositFunds_increasesBalance() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        paymaster.depositFunds{value: TEST_DEPOSIT_FUND}();
        assertGt(paymaster.getDeposit(), 0);
    }

    function test_updatePaymasterSigner_onlyOwner() public {
        address newSigner = makeAddr("newPaymasterSigner");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        paymaster.updatePaymasterSigner(newSigner);
        vm.prank(deployer);
        paymaster.updatePaymasterSigner(newSigner);
        assertEq(paymaster.paymasterSigner(), newSigner);
    }
}
