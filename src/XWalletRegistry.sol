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

    // ERRORS //
    error XWalletRegistry__NullAddress();
}
