// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SmartAccount} from "./SmartAccount.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

/**
 * @author gnvvs-2003
 * @title SmartAccountFactory
 * @notice Deploys SmartAccount contract using CREATE2
 * @notice  CREATE2 is crucial because it lets us compute the smart account
 * address BEFORE deploying it. This means:
 * - Users can receive funds to their smart account before it's deployed
 * - The address is deterministic based on the owner's EOA
 * - No address surprises — same owner always gets same address
 *
 * This factory also serves as a counterfactual account factory —
 * if the smart account doesn't exist yet, it gets deployed as part
 * of the first UserOperation.
 */

contract SmartAccountFactory {
    SmartAccount public immutable accountImplementation;

    // ══════════════════════════════════════════════════════
    //                    CONSTRUCTOR
    // ══════════════════════════════════════════════════════
    constructor(IEntryPoint _entryPoint) {
        /// @dev Initializes SmartAccount
        accountImplementation = new SmartAccount(_entryPoint);
    }
    // ══════════════════════════════════════════════════════
    //                       EVENTS
    // ══════════════════════════════════════════════════════

    event SmartAccountCreated(address indexed owner, address indexed smartAccount, uint256 salt);

    // ══════════════════════════════════════════════════════
    //                 SMART ACCOUNT CREATION
    // ══════════════════════════════════════════════════════

    /**
     * @notice This function creates a SmartAccount for an owner or returns the existing one
     * @notice Uses CREATE2 => address is deterministic
     * @notice If account already exists returns the exsting account address without redeploying
     * @param owner EOA that will control the smart account
     * @param registry XWalletRegistry
     * @param requireXVerification X verification required/not
     * @param account Deployed or existing smart account address
     */

    function createAccount(address owner, address registry, bool requireXVerification, uint256 salt)
        public
        returns (SmartAccount account)
    {
        address addr = getAddress(owner, registry, requireXVerification, salt);
        /// @custom:check If account exists return it
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        if (codeSize > 0) {
            return SmartAccount(payable(addr));
        }
        /// @notice If no account exists => create a proxy account usnig CREATE2 instead of deploying the full contract
        /// @notice Proxy := ERC1967Proxy
        account = SmartAccount(
            // EntryPoint
            payable(new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation),
                    abi.encodeCall(SmartAccount.initialize, (owner, registry, requireXVerification))
                ))
        );
        emit SmartAccountCreated(owner, address(account), salt);
    }

    /// @return address Address of existing SmartAccount
    function getAddress(address owner, address registry, bool requireXVerification, uint256 salt)
        public
        view
        returns (address)
    {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(accountImplementation),
                        abi.encodeCall(SmartAccount.initialize, (owner, registry, requireXVerification))
                    )
                )
            )
        );
    }
}
