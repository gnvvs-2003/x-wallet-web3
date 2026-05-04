// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BasePaymaster} from "@account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {XWalletRegistry} from "./XWalletRegistry.sol";

/**
 * @author gnvvs-2003
 * @title SponserPaymaster
 * @notice ERC-4337 Paymaster contract that pays for user gas
 * @notice Uses IEntryPoint contract to pay for user gas
 * @custom:working
 * 1. Paymaster deposits ETH to this contract
 * 2. When a user wants to make a gasless transaction their backend requests the paymaster signature (off-chain approval)
 * 3. Paymaster countersigns the UserOperation
 * 4. EntryPoint verifies the paymaster signature and pays gas from paymaster deposited ETH
 * @custom:features
 * - Signature based approval
 * - Expiry timestamps on each approval
 * - Only users with verified X gets sponsorship from paymaster
 * - Nonce protection enabled
 */

contract SponserPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using ECDSA for bytes32; // signature verification
    using MessageHashUtils for bytes32; // message hashing

    // ══════════════════════════════════════════════════════
    //                    STATE VARIABLES
    // ══════════════════════════════════════════════════════

    /// @dev Wallet that signs paymaster approvals
    address public paymasterSigner;
    XWalletRegistry public registry;
    /// @dev Max gas cost per operation paid by paymaster
    uint256 public maxGasCostPerOperation;
    /// @dev Total sponsored gas per user
    mapping(address => uint256) public totalSponsoredForUser;
    /// @dev Max sponsor for user
    uint256 public maxSponsorshipPerUser;
    /// @dev Nonce
    mapping(bytes32 => bool) public usedPaymasterNonces;

    // ══════════════════════════════════════════════════════
    //                      CONSTRUCTOR
    // ══════════════════════════════════════════════════════

    constructor(
        IEntryPoint _entryPoint,
        address _paymasterSigner,
        address _registry,
        uint256 _maxGasCostPerOperation,
        uint256 _maxPerUser
    ) BasePaymaster(_entryPoint, msg.sender) {
        if (_paymasterSigner == address(0)) {
            revert SponserPaymaster__NullAddress();
        }
        if (_registry == address(0)) revert SponserPaymaster__NullAddress();
        if (_maxGasCostPerOperation == 0) {
            revert SponserPaymaster__ZeroMaxGasCostPerOperation();
        }
        if (_maxPerUser == 0) {
            revert SponserPaymaster__ZeroMaxSponsorshipPerUser();
        }
        paymasterSigner = _paymasterSigner;
        registry = XWalletRegistry(_registry);
        maxGasCostPerOperation = _maxGasCostPerOperation;
        maxSponsorshipPerUser = _maxPerUser;
    }

    // ══════════════════════════════════════════════════════
    //                      EVENTS
    // ══════════════════════════════════════════════════════

    event GasSponsored(
        address indexed user, address indexed smartAccount, uint256 gasCost, uint256 totalSponsoredForUser
    );

    event PaymasterSignerUpdated(address oldSigner, address newSigner);
    event MaxGasCostUpdated(uint256 oldMax, uint256 newMax);
    event MaxSponsorshipPerUserUpdated(uint256 oldMax, uint256 newMax);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    // ══════════════════════════════════════════════════════
    //   ERC-4337 PAYMASTER VALIDATION : INTERNAL FUNCTION
    // ══════════════════════════════════════════════════════

    /**
     * @notice validates that paymaster covers the gas for this operation
     * @notice called by the EntryPoint during the validation process
     * @notice This function
     * - decodes paymasterAndData : contains paymaster address ,nonce ,expiry and signature
     * @custom:code
     *     ```PackedUserOp.sol
     *             struct PackedUserOperation {
     *             address sender;
     *             uint256 nonce;
     *             bytes initCode;
     *             bytes callData;
     *             bytes32 accountGasLimits;
     *             uint256 preVerificationGas;
     *             bytes32 gasFees;
     *             bytes paymasterAndData; ---->contains our paymaster info
     *             bytes signature;
     *         }
     *     ```
     * - verify paymaster counter signature
     * - checks the user x-verified or not
     * - check gas limit
     * - returns context for postOp to track spending
     * @param userOp UserOperation being validated
     * @param userOpHash Hash of user operation
     * @param maxCost Maximum ETH the paymaster needs to have available
     * @return context PostOp
     * @return validationData
     * - if `0` : successful
     * - if `1` : Failed
     */

    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        /// @dev Decoding paymaster and data
        /// @custom:format paymasterData : address(20)[address of paymaster] + [data starts from here]nonce(32) + expiry(32) + sign(65)
        bytes calldata paymasterData = userOp.paymasterAndData[20:];
        /// @dev Decoding nonce expiry and signature
        (bytes32 pmNonce, uint256 expiry, bytes memory pmSignature) =
            abi.decode(paymasterData, (bytes32, uint256, bytes));
        /// @custom:check Checking for nonce (Anti-replay attack)
        if (usedPaymasterNonces[pmNonce]) {
            revert SponserPaymaster__PaymasterNonceUsed();
        }
        /// @custom:check Expiry check
        if (block.timestamp > expiry) {
            revert SponserPaymaster__PaymasterSignatureExpired();
        }
        /// @custom:verification Paymaster signature Verification using message hash to generate paymaster address
        bytes32 messageHash = keccak256(abi.encodePacked("PAYMASTER_APPROVAL:", userOpHash, pmNonce, expiry));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash(); // converts to standard ETH signed msg
        address recoveredAddr = ethSignedHash.recover(pmSignature);
        /// @custom:check Check if the recovered addr from signature hash is the paymaster
        if (recoveredAddr != paymasterSigner) {
            revert SponserPaymaster__InvalidSignature();
        }
        /// @dev Paymaster signature is verified => X verification
        /// @notice for now check if smart account is verified or its owner is : handled by the registry
        if (maxCost > maxGasCostPerOperation) {
            revert SponserPaymaster__ExceedsMaxGasCost(maxCost, maxGasCostPerOperation);
        }
        /// @custom:check Per user sponsorship limit
        address smartAccount = userOp.sender;
        uint256 newTotal = totalSponsoredForUser[smartAccount] + maxCost;
        if (newTotal > maxSponsorshipPerUser) {
            revert SponserPaymaster__ExceedsUserSponsorLimit(smartAccount, newTotal, maxSponsorshipPerUser);
        }
        ///@notice PostOp context => for updating spending records of user
        context = abi.encode(smartAccount, pmNonce, maxCost);
        validationData = 0;
    }

    // ══════════════════════════════════════════════════════
    //                     POST OPERATION
    // ══════════════════════════════════════════════════════

    /**
     * @dev Called after the operation is executed
     * @dev Updates spending records and marks nonce as used
     *
     */

    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        (address smartAccount, bytes32 pmNonce,) = abi.decode(context, (address, bytes32, uint256));
        // Mark nonce as used to prevent replay attack
        usedPaymasterNonces[pmNonce] = true;
        totalSponsoredForUser[smartAccount] += actualGasCost;
        emit GasSponsored(smartAccount, smartAccount, actualGasCost, totalSponsoredForUser[smartAccount]);
    }

    // ══════════════════════════════════════════════════════
    //                     FUNDING FUNCTIONS
    // ══════════════════════════════════════════════════════

    function depositFunds() external payable {
        entryPoint().depositTo{value: msg.value}(address(this));
        emit FundsDeposited(msg.sender, msg.value);
    }

    function withdrawFunds(address payable recipient, uint256 amount) external onlyOwner {
        entryPoint().withdrawTo(recipient, amount);
        emit FundsWithdrawn(recipient, amount);
    }

    function getDeposit() public view override returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    // ══════════════════════════════════════════════════════
    //                     ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════

    function updatePaymasterSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert SponserPaymaster__NullAddress();
        address oldSigner = paymasterSigner;
        paymasterSigner = newSigner;
        emit PaymasterSignerUpdated(oldSigner, newSigner);
    }

    function updateMaxGasCostPerOp(uint256 newMax) external onlyOwner {
        uint256 old = maxGasCostPerOperation;
        maxGasCostPerOperation = newMax;
        emit MaxGasCostUpdated(old, newMax);
    }

    function updateMaxSponsorshipPerUser(uint256 newMax) external onlyOwner {
        uint256 old = maxSponsorshipPerUser;
        maxSponsorshipPerUser = newMax;
        emit MaxSponsorshipPerUserUpdated(old, newMax);
    }

    receive() external payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    // ══════════════════════════════════════════════════════
    //                     ERRORS
    // ══════════════════════════════════════════════════════

    error SponserPaymaster__NullAddress();
    error SponserPaymaster__ZeroMaxGasCostPerOperation();
    error SponserPaymaster__ZeroMaxSponsorshipPerUser();
    error SponserPaymaster__ExceedsUserSponsorLimit(address, uint256, uint256);
    error SponserPaymaster__PaymasterNonceUsed();
    error SponserPaymaster__PaymasterSignatureExpired();
    error SponserPaymaster__InvalidSignature();
    error SponserPaymaster__ExceedsMaxGasCost(uint256, uint256);
}
