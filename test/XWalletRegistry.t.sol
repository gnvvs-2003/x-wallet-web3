// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XWalletRegistry} from "../src/XWalletRegistry.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @author gnvvs-2003
 * @title XWalletRegistryTest
 * @dev Test code for XWalletRegistry contract
 */

contract XWalletRegistryTest is Test {
    // ══════════════════════════════════════════════════════
    //                    STATE VARIABLES
    // ══════════════════════════════════════════════════════
    XWalletRegistry public registry;
    // ══════════════════════════════════════════════════════
    //                    TEST ACCOUNTS
    // ══════════════════════════════════════════════════════
    address public deployer = makeAddr("deployer");
    address public backendAdddr = makeAddr("backend");
    address public userAlice = makeAddr("alice");
    address public userBob = makeAddr("bob");
    address public attacker = makeAddr("attacker");
    // ══════════════════════════════════════════════════════
    //                    SIGNING KEYS
    // ══════════════════════════════════════════════════════
    uint256 public backendPrivateKey;
    address public backendSigner;
    // ══════════════════════════════════════════════════════
    //                       TEST DATA
    // ══════════════════════════════════════════════════════
    string constant ALICE_USERNAME = "alice_eth";
    string constant ALICE_X_ID = "123456789";
    string constant BOB_USERNAME = "bob_eth";
    string constant BOB_X_ID = "987654321";

    // ══════════════════════════════════════════════════════
    //                         SETUP
    // ══════════════════════════════════════════════════════
    function setUp() public {
        /// @dev backendSigner and backendPrivate key
        backendPrivateKey = 0xABCDEF132;
        backendSigner = vm.addr(backendPrivateKey);
        vm.prank(deployer);
        /// @notice Deploy XWalletRegistry contract with deployer (sets owner of registry as deployer)
        registry = new XWalletRegistry(backendSigner);
    }

    // ══════════════════════════════════════════════════════
    //                     DEPLOYED TESTS
    // ══════════════════════════════════════════════════════
    function test_deployment_address_is_backendSigner() public view {
        assertEq(registry.backendSigner(), backendSigner);
    }

    function test_deployment_sets_ownerAs_deployer() public view {
        assertEq(registry.owner(), deployer);
    }

    // ══════════════════════════════════════════════════════
    //                     LINK USERNAME TESTS
    // ══════════════════════════════════════════════════════
    function test_linkusername_success() public {
        bytes32 nonce = keccak256("test-nonce-1");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
        assertEq(registry.usernameToWallet("alice_eth"), userAlice);
        assertEq(registry.walletToUsername(userAlice), "alice_eth");
        assertEq(registry.isVerified(userAlice), true);
    }

    function test_linkusername_emitsEvent() public {
        bytes32 nonce = keccak256("test-nonce-2");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        vm.expectEmit(true, false, false, false);
        emit XWalletRegistry.UsernameLinked(userAlice, "alice_eth", block.timestamp);
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
    }

    function test_linkUsername_caseInsensitive() public {
        // Link with mixed case username
        bytes32 nonce = keccak256("test-nonce-case");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory signature = _createBackendSignature(userAlice, "Alice_ETH", ALICE_X_ID, nonce, expiry);
        vm.prank(userAlice);
        registry.linkUsername("Alice_ETH", ALICE_X_ID, nonce, expiry, signature);
        // Should be stored as lowercase
        assertEq(registry.walletToUsername(userAlice), "alice_eth", "Should store username as lowercase");
    }

    // ══════════════════════════════════════════════════════
    //         LINK USERNAME - SIGNATURE TESTS
    // ══════════════════════════════════════════════════════
    function test_linkusername_revertOnExpiredSignature() public {
        bytes32 nonce = keccak256("test-nonce-expired");
        uint256 expiry = block.timestamp - 1; // Already expired
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        vm.prank(userAlice);
        vm.expectRevert(XWalletRegistry.XWalletRegistry__LinkExpired.selector);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
    }

    function test_linkusername_revertsOnInvalidSignature() public {
        bytes32 nonce = keccak256("test-nonce-invalid");
        uint256 expiry = block.timestamp + 15 minutes; // Valid expiry
        // Creating a wrong key to generate a invalid signature
        uint256 wrongKey = 0xAB1242;
        bytes32 messageHash = keccak256(
            abi.encodePacked("LINK_X_WALLET", userAlice, ":", ALICE_USERNAME, ":", ALICE_X_ID, ":", nonce, ":", expiry)
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        vm.prank(userAlice);
        vm.expectRevert(XWalletRegistry.XWalletRegistry__InvalidSignature.selector);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, invalidSignature);
    }

    // ══════════════════════════════════════════════════════
    //         LINK USERNAME - NONCE TESTS
    // ══════════════════════════════════════════════════════
    function test_linkUsername_revertsOnReusedNonce() public {
        bytes32 nonce = keccak256("test-nonce-reuse");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        // First link — should succeed
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
        // Alice unlinks so we can test nonce reuse independently
        vm.prank(userAlice);
        registry.unlinkUsername();
        // Try to use same nonce again — should fail
        vm.prank(userAlice);
        vm.expectRevert(XWalletRegistry.XWalletRegistry__NonceUsed.selector);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
    }

    // ══════════════════════════════════════════════════════
    //         LINK USERNAME - DUPLICATES
    // ══════════════════════════════════════════════════════
    function test_linkusername_revertsIfUsernameAlreadyTaken() public {
        // Alice links first
        bytes32 nonceA = keccak256("nonce-a");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory sigA = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonceA, expiry);
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonceA, expiry, sigA);

        // Bob tries to link the same username
        bytes32 nonceB = keccak256("nonce-b");
        bytes memory sigB = _createBackendSignature(userBob, ALICE_USERNAME, BOB_X_ID, nonceB, expiry);
        vm.prank(userBob);
        vm.expectRevert(
            abi.encodeWithSelector(
                XWalletRegistry.XWalletRegistry__UsernameAlreadyLinked.selector, ALICE_USERNAME, userAlice
            )
        );
        registry.linkUsername(ALICE_USERNAME, BOB_X_ID, nonceB, expiry, sigB);
    }

    // ══════════════════════════════════════════════════════
    //               UNLINK USERNAME TESTS
    // ══════════════════════════════════════════════════════
    function test_unlinkusername_success() public {
        // First link
        bytes32 nonce = keccak256("unlink-nonce");
        uint256 expiry = block.timestamp + 15 minutes;
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
        // Then unlink
        vm.prank(userAlice);
        registry.unlinkUsername();
        // Verify cleanup
        assertEq(registry.usernameToWallet("alice_eth"), address(0));
        assertEq(registry.walletToUsername(userAlice), "");
        assertFalse(registry.isVerified(userAlice));
    }

    function test_unlinkusername_revertsIfNotLinked() public {
        vm.prank(userAlice);
        vm.expectRevert(XWalletRegistry.XWalletRegistry__UserNotLinked.selector);
        registry.unlinkUsername();
    }

    // ══════════════════════════════════════════════════════
    //         ADMIN FUNCTIONS TESTS
    // ══════════════════════════════════════════════════════
    function test_updateBackendSigner_onlyOwner() public {
        /// @dev The deployer is set as owner in  setUp
        address newSigner = makeAddr("newSigner");
        vm.prank(attacker);
        vm.expectRevert();
        registry.updateBackendSigner(newSigner);
        vm.prank(deployer);
        registry.updateBackendSigner(newSigner);
        assertEq(registry.backendSigner(), newSigner);
    }

    // ══════════════════════════════════════════════════════
    //                       FUZZ TESTS
    // ══════════════════════════════════════════════════════
    function test_linkusername_fuzz_validParamsAlwaysSucceed(uint256 nonceRand, uint256 expiryOffset) public {
        uint256 expiry = block.timestamp + bound(expiryOffset, 60, 86400);
        bytes32 nonce = keccak256(abi.encodePacked(nonceRand));
        bytes memory signature = _createBackendSignature(userAlice, ALICE_USERNAME, ALICE_X_ID, nonce, expiry);
        vm.prank(userAlice);
        registry.linkUsername(ALICE_USERNAME, ALICE_X_ID, nonce, expiry, signature);
        assertTrue(registry.isVerified(userAlice));
    }

    // ══════════════════════════════════════════════════════
    //         HELPER - BACKEND SIGNATURE CREATION
    // ══════════════════════════════════════════════════════
    function _createBackendSignature(
        address wallet,
        string memory username,
        string memory userId,
        bytes32 nonce,
        uint256 expiry
    ) internal returns (bytes memory) {
        /// @custom:process
        /// 1. Build message hash
        bytes32 messageHash =
            keccak256(abi.encodePacked("LINK_X_WALLET", wallet, ":", username, ":", userId, ":", nonce, ":", expiry));
        /// 2. Apply ETH standard
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        /// 3. Sign with backend private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPrivateKey, ethSignedHash);
        /// 4. returns the signature in encoded format
        return abi.encodePacked(r, s, v);
    }
}
