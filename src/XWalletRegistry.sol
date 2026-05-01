// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @author gnvvs-2003
 * @title XWalletRegistry
 * @notice This contract is the on-chain connection between x usernames and wallet addresses
 * @notice This contract uses ECDSA signature verification to ensure only our authorized backend can confirm X identity links
 * @notice Stores verification status of each link and timestamp of when the link was created
 * @custom:steps
 * # 1. Link between is established by a backend that has the verified user X OAuth session
 * # 2. Backend signs the message confirming the link between x user and wallet address
 */

contract XWalletRegistry is Ownable, ReentrancyGuard {
    using ECDSA for bytes32; // signature verification
    using MessageHashUtils for bytes32; // message hashing

    // STATE VARIABLES //

    /// @dev The backendSigner address that is authorized to approve links between x and wallet
    address public backendSigner;
    /// @dev Mapping between wallet and x username
    mapping(address => string) public walletToUsername;
    mapping(string => address) public usernameToWallet;
    /// @dev Mapping of verified status of wallet
    mapping(address => bool) public isVerified;
    /// @dev Timestamp of when link was verified
    mapping(address => uint256) public verifedAt;
    /// @dev Prevents signature replay attacks
    /// @notice using nonce
    mapping(bytes32 => bool) public usedNonces;

    // CONSTRUCTOR //

    /**
     * @param _backendSigner address used by the server to sign link aprovals
     */
    constructor(address _backendSigner) Ownable(msg.sender) {
        if (_backendSigner == address(0)) revert XWalletRegistry__NullAddress();
        backendSigner = _backendSigner;
    }

    // MAIN FUNCTIONS //
    /**
     * @notice Links an X username to a wallet address
     * @dev The caller provides a signature from the backend server.
     *      The signature proves the backend verified the X OAuth session.
     * @param username The X username to link
     * @param xUserId The X user ID to link
     * @param nonce A nonce used to prevent signature replay attacks
     * @param expiry The expiry time of the link
     * @param backendSig The backend's ECDSA signature of the link params
     * @custom:Working
     * #1. User log in with X via OAuth
     * #2. Backend verifies X identity => creates a signed message
     * #3. This function is called by the frontend with backend signature
     *
     */
    function linkUsername(
        string calldata username,
        string calldata xUserId,
        bytes32 nonce,
        uint256 expiry,
        bytes calldata backendSig
    ) external nonReentrant {
        if (bytes(username).length == 0) revert XWalletRegistry__EmptyUsername();
        if (bytes(xUserId).length == 0) revert XWalletRegistry__EmptyUserId();
        if (block.timestamp > expiry) revert XWalletRegistry__LinkExpired();
        if (usedNonces[nonce]) revert XWalletRegistry__NonceUsed();
    }

    // ERRORS //
    error XWalletRegistry__NullAddress();
}
