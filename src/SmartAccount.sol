// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {XWalletRegistry} from "./XWalletRegistry.sol";

/**
 * @author gnvvs-2003
 * @title SmartAccount
 * @notice ERC-4337 compatible smart account
 * @notice Each user deploys one of these to blockchain
 * @notice This account is controlled by owners EOA but transactions are submitted through ERC-4337 EntryPoint contract
 * @custom:capabilities
 *  - Validate user operations signed by the EOA
 * - Execute arbitrary calls (send ETH, call contracts)
 * - Work with Paymaster for gasless transactions
 * - Verify the owner has a linked X username before executing
 */

contract SmartAccount is IAccount, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using UserOperationLib for PackedUserOperation;

    // ══════════════════════════════════════════════════════
    //                       STATE VARIABLES
    // ══════════════════════════════════════════════════════

    /// @notice ERC-4337 EntryPoint contract
    IEntryPoint public immutable I_ENTRYPOINT;
    /// @notice XWalletRegistry contract
    XWalletRegistry public i_xWalletRegistry;
    /// @notice Owner of the smart account : EOA
    address public owner;
    /// @notice Whether X verification is required for all transactions
    bool public requireXVerification;
    /// @notice Nonce (seperate from ERC4337 nonce)
    uint256 private _nonce;

    // ══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ══════════════════════════════════════════════════════

    /**
     * @param _entryPoint The ERC-4337 EntryPoint contract address.
     *                    On Sepolia, this is a well-known deployed address.
     */
    constructor(IEntryPoint _entryPoint) {
        I_ENTRYPOINT = _entryPoint;
        _disableInitializers();
    }

    // ══════════════════════════════════════════════════════
    //                       MODIFIERS
    // ══════════════════════════════════════════════════════

    modifier onlyEntryPoint() {
        _onlyEntryPoint();
        _;
    }

    function _onlyEntryPoint() internal view {
        if (msg.sender != address(I_ENTRYPOINT)) revert SmartAccount__NotEntryPoint();
    }

    modifier onlyEntryPointOrOwner() {
        _onlyEntryPointOrOwner();
        _;
    }

    function _onlyEntryPointOrOwner() internal view {
        if (msg.sender != address(I_ENTRYPOINT) && msg.sender != owner) revert SmartAccount__NotEntryPointOrOwner();
    }

    // ══════════════════════════════════════════════════════
    //                       EVENTS
    // ══════════════════════════════════════════════════════

    event SmartAccountExecuted(address indexed target, uint256 value, bytes data, uint256 nonce);
    event SmartAccountExecutedBatch(address[] indexed targets, uint256[] values, bytes[] datas, uint256 nonce);
    event OwnerUpdated(address indexed newOwner, address indexed oldOwner);

    // ══════════════════════════════════════════════════════
    //                     INITIALIZATION
    // ══════════════════════════════════════════════════════

    /**
     * @dev Initializes the smart account
     * @param _owner The owner of the smart account (EOA)
     * @param _registry The XWalletRegistry contract address
     * @param _requireVerification Whether X verification is required for all transactions
     */
    function initialize(address _owner, address _registry, bool _requireVerification) public initializer {
        if (_owner == address(0)) revert SmartAccount__NullAddress();
        if (_registry == address(0)) revert SmartAccount__NullAddress();
        owner = _owner;
        requireXVerification = _requireVerification;
        i_xWalletRegistry = XWalletRegistry(_registry);
    }

    // ══════════════════════════════════════════════════════
    //                  ERC-4337 VALIDATION
    // ══════════════════════════════════════════════════════

    /**
     * @dev This is the core ERC-4337 function
     * @notice Validates userOp before execution
     * @param userOp The user operation to validate
     * @param userOpHash The hash of the user operation
     * @param missingAccountFunds The amount of funds missing from the account
     * @return validationData Validation data - packed 4 bytes with signature length, callGasLimit and verificationGasLimit
     */

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        onlyEntryPoint
        returns (uint256 validationData)
    {
        /// @dev Signature validation
        validationData = _validateSignature(userOp, userOpHash);
        /// @dev X Verification
        if (requireXVerification && !i_xWalletRegistry.isVerified(owner)) {
            return 1;
        }
        /// @dev EntryPoint pay
        if (missingAccountFunds > 0) {
            // Transfer funds to EntryPoint for transaction gas fee
            (bool success,) = address(I_ENTRYPOINT).call{value: missingAccountFunds}("");
            if (!success) {
                revert SmartAccount__ExecutionFailed();
            }
            (success);
        }
    }

    // ══════════════════════════════════════════════════════
    //                  EXECUTION FUNCTIONS
    // ══════════════════════════════════════════════════════

    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPointOrOwner nonReentrant {
        _incrementNonce();
        _call(target, value, data);
        emit SmartAccountExecuted(target, value, data, _nonce);
    }

    /// @dev Batch Execution : Performs multiple transactions in a single call
    /// @dev Performs in atomic way : One fails => all fails
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas)
        external
        onlyEntryPointOrOwner
        nonReentrant
    {
        if (targets.length != values.length || values.length != datas.length) {
            revert SmartAccount__AddressAndValuesAndDataLengthMismatch();
        }
        _incrementNonce();
        for (uint256 i = 0; i < targets.length; i++) {
            _call(targets[i], values[i], datas[i]);
        }
        emit SmartAccountExecutedBatch(targets, values, datas, _nonce);
    }

    // ══════════════════════════════════════════════════════
    //                     VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════

    function getLinkedUsername() external view returns (string memory) {
        return i_xWalletRegistry.walletToUsername(owner);
    }

    function getNonce() external view returns (uint256) {
        return I_ENTRYPOINT.getNonce(address(this), 0);
    }

    function hasXVerification() external view returns (bool) {
        return i_xWalletRegistry.isVerified(owner);
    }

    // ══════════════════════════════════════════════════════
    //                   INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        returns (uint256 validationData)
    {
        /// @dev Ehereum personal sign
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recoveredSigner = hash.recover(userOp.signature);
        if (recoveredSigner == owner) {
            return 0;
        } else {
            return 1;
        }
    }

    //Call function
    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success,) = target.call{value: value}(data);
        if (!success) {
            revert SmartAccount__ExecutionFailed();
        }
    }

    // Nonce increment
    function _incrementNonce() internal {
        _nonce++;
    }

    // ══════════════════════════════════════════════════════
    //                        UPGRADES
    // ══════════════════════════════════════════════════════

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != owner) revert SmartAccount__NotOwner();
    }

    // ══════════════════════════════════════════════════════
    //                       RECEIVE
    // ══════════════════════════════════════════════════════

    receive() external payable {}

    // ══════════════════════════════════════════════════════
    //                       ERRORS
    // ══════════════════════════════════════════════════════
    error SmartAccount__NotEntryPoint();
    error SmartAccount__NotEntryPointOrOwner();
    error SmartAccount__NullAddress();
    error SmartAccount__ExecutionFailed();
    error SmartAccount__AddressAndValuesAndDataLengthMismatch();
    error SmartAccount__NotOwner();
    error SmartAccount__InvalidSignature();
}
