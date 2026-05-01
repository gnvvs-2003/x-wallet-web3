// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";

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

    // STATE VARIABLES //
    /// @notice ERC-4337 EntryPoint contract
    IEntryPoint public immutable I_ENTRYPOINT;
    /// @notice XWalletRegistry contract
    XWalletRegistry public immutable I_X_WALLET_REGISTRY;
    /// @notice Owner of the smart account : EOA
    address public owner;
    /// @notice Whether X verification is required for all transactions
    bool public requireXVerification;
    /// @notice Nonce (seperate from ERC4337 nonce)
    uint256 private _nonce;
}
