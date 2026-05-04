# Architecture:
![Architecture](image.png)

# Workflow and code integration
1. User Identity Linking `XWalletRegistry.sol` contract
```solidity
function linkUsername(
    string calldata username,
    string calldata xUserId,
    bytes32 nonce,
    uint256 expiry,
    bytes calldata backendSig
) external nonReentrant {
    // 1. Recreate the message the backend signed
    bytes32 messageHash = keccak256(abi.encodePacked("LINK_X_WALLET:", msg.sender, ":", username, ":", xUserId, ":", nonce, ":", expiry));
    
    // 2. Recover the signer from the signature
    address recoveredSigner = messageHash.toEthSignedMessageHash().recover(backendSig);
    
    // 3. Verify it's the authorized backend
    if (recoveredSigner != backendSigner) revert InvalidSignature();
    
    // 4. Record the link on-chain
    usernameToWallet[lowerUsername] = msg.sender;
    isVerified[msg.sender] = true;
}
```

2. Requesting Gas Sponsorship (*Off-chain*)
When the user wants to execute a transaction, they create a `UserOperation` and send it to the backend server instead of directly to the network. The backend checks:

- Is this wallet verified in the `XWalletRegistry`?
- Has the user exceeded their daily sponsorship limit?
- Is the destination safe?
If everything is valid, the backend creates a signature over the `UserOperation` hash and returns it.

3. Paymaster Validation via `SponserPaymaster.sol` contract

```solidity
function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost) internal override returns (bytes memory context, uint256 validationData) {
    // 1. Extract the paymaster signature from the UserOperation
    bytes calldata paymasterData = userOp.paymasterAndData[20:];
    (bytes32 pmNonce, uint256 expiry, bytes memory pmSignature) = abi.decode(paymasterData, (bytes32, uint256, bytes));
    
    // 2. Recreate the message and recover the signer
    bytes32 messageHash = keccak256(abi.encodePacked("PAYMASTER_APPROVAL:", userOpHash, pmNonce, expiry));
    address recoveredAddr = messageHash.toEthSignedMessageHash().recover(pmSignature);
    
    // 3. Check that the backend actually signed off on sponsoring THIS specific UserOp
    if (recoveredAddr != paymasterSigner) {
        revert SponserPaymaster__InvalidSignature();
    }
    
    // 4. Ensure we don't sponsor more than allowed
    uint256 newTotal = totalSponsoredForUser[userOp.sender] + maxCost;
    if (newTotal > maxSponsorshipPerUser) {
        revert SponserPaymaster__ExceedsUserSponsorLimit(userOp.sender, newTotal, maxSponsorshipPerUser);
    }
    
    // Return the context to be used in _postOp for updating limits
    context = abi.encode(userOp.sender, pmNonce, maxCost);
    return (context, 0);
}
```

4. Post operation : Tracking gas usage
Once the transaction is executed by the Smart Account, the EntryPoint calls the Paymaster back to finalize accounting.

```solidity
function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas) internal override {
    (address smartAccount, bytes32 pmNonce, ) = abi.decode(context, (address, bytes32, uint256));
    
    // Prevent the same signature from being used again (replay protection)
    usedPaymasterNonces[pmNonce] = true;
    
    // Add the actual gas used to the user's running total
    totalSponsoredForUser[smartAccount] += actualGasCost;
}
```