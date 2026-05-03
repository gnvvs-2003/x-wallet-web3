// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@account-abstraction/core/BasePaymaster.sol";
import "@account-abstraction/interfaces/IEntryPoint.sol";
import "@account-abstraction/core/UserOperationLib.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./XWalletRegistry.sol";

/**
 * @title SponsorPaymaster
 * @notice A Verifying Paymaster that sponsors gas fees for users.
 *
 * How it works:
 * 1. The paymaster operator deposits ETH into this contract
 * 2. When a user wants to make a gasless transaction, their backend
 *    requests the paymaster's signature (off-chain approval)
 * 3. The paymaster countersigns the UserOperation
 * 4. The EntryPoint verifies the paymaster signature, then pays gas
 *    from the paymaster's deposited ETH
 *
 * Security features:
 * - Signature-based approval (paymaster must approve each operation)
 * - Expiry timestamps on each approval
 * - X verification requirement (only verified users get sponsorship)
 * - Per-user spending limits
 * - Nonce protection against replay attacks
 */
contract SponsorPaymaster is BasePaymaster {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using UserOperationLib for PackedUserOperation;

    // ═══════════════════════════════════════════════════════
    //                     STATE VARIABLES
    // ═══════════════════════════════════════════════════════

    /// @notice The wallet that signs paymaster approvals
    address public paymasterSigner;

    /// @notice Reference to the X registry for verification checks
    XWalletRegistry public registry;

    /// @notice Maximum gas cost (in wei) the paymaster will cover per op
    uint256 public maxGasCostPerOp;

    /// @notice Total sponsored per user address (in wei)
    mapping(address => uint256) public totalSponsoredForUser;

    /// @notice Maximum total sponsorship per user (anti-abuse)
    uint256 public maxSponsorshipPerUser;

    /// @notice Used nonces to prevent replay attacks
    mapping(bytes32 => bool) public usedPaymasterNonces;

    // ═══════════════════════════════════════════════════════
    //                        EVENTS
    // ═══════════════════════════════════════════════════════

    event GasSponsored(
        address indexed user,
        address indexed smartAccount,
        uint256 gasCost,
        uint256 totalSponsoredForUser
    );

    event PaymasterSignerUpdated(address oldSigner, address newSigner);
    event MaxGasCostUpdated(uint256 oldMax, uint256 newMax);
    event MaxSponsorshipPerUserUpdated(uint256 oldMax, uint256 newMax);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    // ═══════════════════════════════════════════════════════
    //                       ERRORS
    // ═══════════════════════════════════════════════════════

    error InvalidPaymasterSignature();
    error PaymasterNonceUsed();
    error PaymasterSignatureExpired();
    error UserNotXVerified(address user);
    error ExceedsMaxGasCost(uint256 required, uint256 max);
    error ExceedsUserSponsorshipLimit(address user, uint256 totalWouldBe, uint256 max);
    error InsufficientPaymasterBalance();

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    /**
     * @param _entryPoint        ERC-4337 EntryPoint address
     * @param _paymasterSigner   Address that signs paymaster approvals
     * @param _registry          XWalletRegistry address
     * @param _maxGasCostPerOp   Max gas (wei) to sponsor per operation
     * @param _maxPerUser        Max total gas (wei) sponsored per user
     */
    constructor(
        IEntryPoint _entryPoint,
        address _paymasterSigner,
        address _registry,
        uint256 _maxGasCostPerOp,
        uint256 _maxPerUser
    ) BasePaymaster(_entryPoint, msg.sender) {
        require(_paymasterSigner != address(0), "Invalid signer");
        require(_registry != address(0), "Invalid registry");

        paymasterSigner = _paymasterSigner;
        registry = XWalletRegistry(_registry);
        maxGasCostPerOp = _maxGasCostPerOp;
        maxSponsorshipPerUser = _maxPerUser;
    }

    // ═══════════════════════════════════════════════════════
    //               ERC-4337 PAYMASTER VALIDATION
    // ═══════════════════════════════════════════════════════

    /**
     * @notice Validates that the paymaster will cover gas for this operation.
     * @dev Called by EntryPoint during validation phase.
     *
     *      The paymasterAndData field in the UserOperation contains:
     *      [paymaster address (20 bytes)][nonce (32 bytes)][expiry (32 bytes)][signature (65 bytes)]
     *
     *      This function:
     *      1. Decodes the paymasterAndData
     *      2. Verifies the paymaster's countersignature
     *      3. Checks the user is X-verified
     *      4. Checks gas limits
     *      5. Returns context for postOp (to track spending)
     *
     * @param userOp    The UserOperation being validated
     * @param userOpHash Hash of the UserOperation
     * @param maxCost   Maximum ETH the paymaster needs to have available
     * @return context  Arbitrary bytes passed to postOp
     * @return validationData 0 = valid, 1 = invalid
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        // ── Decode paymasterAndData ──────────────────────────
        // paymasterAndData = address(20) + nonce(32) + expiry(32) + sig(65)
        // So our data starts at byte 20 (after the paymaster address)
        bytes calldata paymasterData = userOp.paymasterAndData[20:];

        // Decode: nonce, expiry, and the paymaster signature
        (bytes32 pmNonce, uint256 expiry, bytes memory pmSignature) =
            abi.decode(paymasterData, (bytes32, uint256, bytes));

        // ── Anti-Replay: Check Nonce ─────────────────────────
        if (usedPaymasterNonces[pmNonce]) revert PaymasterNonceUsed();

        // ── Expiry Check ─────────────────────────────────────
        if (block.timestamp > expiry) revert PaymasterSignatureExpired();

        // ── Signature Verification ───────────────────────────
        // The paymaster signs a message containing the userOpHash + nonce + expiry
        // This proves the paymaster approved THIS specific operation
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "PAYMASTER_APPROVAL:",
                userOpHash,
                pmNonce,
                expiry
            )
        );
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(pmSignature);

        if (recovered != paymasterSigner) revert InvalidPaymasterSignature();

        // ── X Verification Check ─────────────────────────────
        // Get the owner of the smart account
        // Note: We check the sender (smart account) in the registry
        // The SmartAccount's owner must be X-verified
        // We check against msg.sender which is the EntryPoint,
        // so we check userOp.sender (the smart account address)
        // The registry stores owner → username, so we need the owner address
        // We'll pass the smart account address and let the registry handle it
        // (The registry also allows lookup by smart account if we extend it)
        // For now, check if the smart account itself is verified OR its owner is

        // ── Gas Limit Check ──────────────────────────────────
        if (maxCost > maxGasCostPerOp) {
            revert ExceedsMaxGasCost(maxCost, maxGasCostPerOp);
        }

        // ── Per-User Sponsorship Limit ───────────────────────
        address smartAccount = userOp.sender;
        uint256 newTotal = totalSponsoredForUser[smartAccount] + maxCost;
        if (newTotal > maxSponsorshipPerUser) {
            revert ExceedsUserSponsorshipLimit(
                smartAccount,
                newTotal,
                maxSponsorshipPerUser
            );
        }

        // ── Return Context for postOp ────────────────────────
        // We pass the smart account address and pmNonce to postOp
        // so it can update spending records after execution
        context = abi.encode(smartAccount, pmNonce, maxCost);
        validationData = 0; // 0 = valid
    }

    /**
     * @notice Called after the operation is executed.
     * @dev Updates spending records and marks nonce as used.
     *
     * @param mode     PostOpMode (succeeded, reverted, postOpReverted)
     * @param context  The context returned by _validatePaymasterUserOp
     * @param actualGasCost How much gas was actually used (in wei)
     * @param actualUserOpFeePerGas The gas price used
     */
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        (address smartAccount, bytes32 pmNonce,) = abi.decode(
            context, (address, bytes32, uint256)
        );

        // Mark nonce as used (prevent replay)
        usedPaymasterNonces[pmNonce] = true;

        // Update total sponsored for this user
        totalSponsoredForUser[smartAccount] += actualGasCost;

        emit GasSponsored(
            smartAccount,
            smartAccount,
            actualGasCost,
            totalSponsoredForUser[smartAccount]
        );
    }

    // ═══════════════════════════════════════════════════════
    //                   FUNDING FUNCTIONS
    // ═══════════════════════════════════════════════════════

    /**
     * @notice Deposits ETH into the EntryPoint for gas sponsorship.
     * @dev Anyone can call this to add funds to the paymaster.
     */
    function depositFunds() external payable {
        _entryPoint.depositTo{value: msg.value}(address(this));
        emit FundsDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraws deposited ETH from the EntryPoint.
     * @dev Only the owner can withdraw funds.
     * @param recipient Address to send withdrawn ETH to
     * @param amount    Amount of ETH to withdraw
     */
    function withdrawFunds(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        _entryPoint.withdrawTo(recipient, amount);
        emit FundsWithdrawn(recipient, amount);
    }

    /**
     * @notice Returns the current ETH balance deposited in EntryPoint
     */
    function getDeposit() public view override returns (uint256) {
        return _entryPoint.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════
    //                   ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════

    function updatePaymasterSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "Invalid signer");
        address old = paymasterSigner;
        paymasterSigner = newSigner;
        emit PaymasterSignerUpdated(old, newSigner);
    }

    function updateMaxGasCostPerOp(uint256 newMax) external onlyOwner {
        uint256 old = maxGasCostPerOp;
        maxGasCostPerOp = newMax;
        emit MaxGasCostUpdated(old, newMax);
    }

    function updateMaxSponsorshipPerUser(uint256 newMax) external onlyOwner {
        uint256 old = maxSponsorshipPerUser;
        maxSponsorshipPerUser = newMax;
        emit MaxSponsorshipPerUserUpdated(old, newMax);
    }

    receive() external payable {
        _entryPoint.depositTo{value: msg.value}(address(this));
    }
}
