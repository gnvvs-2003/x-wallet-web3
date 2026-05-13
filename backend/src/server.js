require('dotenv').config();
const express    = require('express');
const cors       = require('cors');
const { ethers } = require('ethers');
const axios      = require('axios');
const jwt        = require('jsonwebtoken');
const crypto     = require('crypto');

const app = express();
app.use(cors({ origin: process.env.FRONTEND_URL || 'http://localhost:5173' }));
app.use(express.json());

// ── Providers and Signers ────────────────────────────────
const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);

// Backend signer — this is the address set as backendSigner in the registry
const backendWallet = new ethers.Wallet(process.env.BACKEND_SIGNER_PRIVATE_KEY, provider);

// Paymaster signer — this is the address set as paymasterSigner in the paymaster
const paymasterWallet = new ethers.Wallet(process.env.PAYMASTER_PRIVATE_KEY, provider);

console.log('Backend signer address:', backendWallet.address);
console.log('Paymaster signer address:', paymasterWallet.address);

// ════════════════════════════════════════════════════════
//                   AUTH ROUTES
// ════════════════════════════════════════════════════════

/**
 * POST /api/auth/x/callback
 *
 * Exchanges an X OAuth authorization code for user information.
 * The frontend sends us the auth code after X redirects back.
 *
 * Flow:
 * 1. Exchange code + verifier for access token (server-side)
 * 2. Use access token to fetch user's X ID and username
 * 3. Create a session JWT for subsequent API calls
 * 4. Return user info to frontend
 */
app.post('/api/auth/x/callback', async (req, res) => {
  const { code, codeVerifier } = req.body;

  if (!code || !codeVerifier) {
    return res.status(400).json({ error: 'Missing code or codeVerifier' });
  }

  try {
    // ── Step 1: Exchange code for access token ───────────
    const tokenResponse = await axios.post(
      'https://api.twitter.com/2/oauth2/token',
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: process.env.TWITTER_REDIRECT_URI,
        client_id: process.env.TWITTER_CLIENT_ID,
        code_verifier: codeVerifier
      }).toString(),
      {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          // Some endpoints require basic auth
          'Authorization': 'Basic ' + Buffer.from(
            `${process.env.TWITTER_CLIENT_ID}:${process.env.TWITTER_CLIENT_SECRET}`
          ).toString('base64')
        }
      }
    );

    const { access_token } = tokenResponse.data;

    // ── Step 2: Fetch user info from X API ───────────────
    const userResponse = await axios.get(
      'https://api.twitter.com/2/users/me?user.fields=id,username,name',
      { headers: { Authorization: `Bearer ${access_token}` } }
    );

    const { id: xUserId, username } = userResponse.data.data;

    // ── Step 3: Create session JWT ───────────────────────
    // This JWT proves the user authenticated with X
    // The frontend stores this and sends it with subsequent requests
    const sessionToken = jwt.sign(
      { xUserId, username, xAccessToken: access_token },
      process.env.JWT_SECRET,
      { expiresIn: '24h' }
    );

    // ── Step 4: Return user info ─────────────────────────
    res.json({
      username,
      xUserId,
      accessToken: sessionToken  // Our app's JWT, not X's token
    });

  } catch (error) {
    console.error('X OAuth error:', error.response?.data || error.message);
    res.status(500).json({
      error: 'OAuth exchange failed',
      details: error.response?.data || error.message
    });
  }
});

/**
 * POST /api/auth/link
 *
 * Creates a backend-signed authorization to link an X account to a wallet.
 * This is the bridge between X's OAuth world and Ethereum's signature world.
 *
 * The frontend calls this after:
 * 1. User has connected their MetaMask wallet
 * 2. User has authenticated with X
 * 3. User wants to create the on-chain link
 *
 * We verify both sides:
 * - X identity: verified by the JWT containing X user info
 * - Wallet address: provided by the frontend (user will submit from this wallet)
 *
 * We then sign a message that the registry contract can verify.
 */
app.post('/api/auth/link', requireAuth, async (req, res) => {
  const { walletAddress } = req.body;
  const { xUserId, username } = req.user; // From JWT middleware

  if (!walletAddress || !ethers.isAddress(walletAddress)) {
    return res.status(400).json({ error: 'Invalid wallet address' });
  }

  try {
    // ── Create a unique nonce ────────────────────────────
    // This prevents the signature from being replayed
    const nonceBytes = crypto.randomBytes(32);
    const nonce = ethers.hexlify(nonceBytes);

    // ── Set expiry (15 minutes from now) ─────────────────
    const expiry = Math.floor(Date.now() / 1000) + (15 * 60);

    // ── Build the message to sign ────────────────────────
    // This MUST match exactly what the contract verifies
    const messageHash = ethers.keccak256(
      ethers.solidityPacked(
        ['string', 'address', 'string', 'string', 'string', 'string', 'string', 'bytes32', 'string', 'uint256'],
        [
          'LINK_X_WALLET:',
          walletAddress,
          ':',
          username,
          ':',
          xUserId,
          ':',
          nonce,
          ':',
          expiry
        ]
      )
    );

    // ── Sign with Ethereum prefix ─────────────────────────
    // signMessage() adds the "\x19Ethereum Signed Message:\n32" prefix
    // This matches what MessageHashUtils.toEthSignedMessageHash() does in Solidity
    const backendSignature = await backendWallet.signMessage(
      ethers.getBytes(messageHash)
    );

    // ── Return signing data to frontend ──────────────────
    res.json({
      username,
      xUserId,
      nonce,
      expiry,
      backendSignature
    });

  } catch (error) {
    console.error('Link signing error:', error);
    res.status(500).json({ error: 'Failed to create authorization' });
  }
});

// ════════════════════════════════════════════════════════
//                TRANSACTION ROUTES
// ════════════════════════════════════════════════════════

/**
 * POST /api/transactions/build
 *
 * Builds an ERC-4337 UserOperation for a gasless transaction.
 * Returns the UserOperation and its hash for the user to sign.
 */
app.post('/api/transactions/build', requireAuth, async (req, res) => {
  const {
    smartAccount, owner, target, value, data,
    isDeployed, registryAddress
  } = req.body;

  try {
    const entryPoint = new ethers.Contract(
      process.env.ENTRY_POINT_ADDRESS,
      ENTRY_POINT_ABI,
      provider
    );

    // ── Get current nonce from EntryPoint ─────────────────
    const nonce = await entryPoint.getNonce(smartAccount, 0);

    // ── Build initCode (for account deployment) ───────────
    // If smart account isn't deployed yet, we include factory call
    let initCode = '0x';
    if (!isDeployed) {
      const factory = new ethers.Contract(
        process.env.FACTORY_ADDRESS,
        FACTORY_ABI,
        provider
      );
      // Encode the factory call to createAccount()
      const factoryCalldata = factory.interface.encodeFunctionData(
        'createAccount',
        [owner, registryAddress, false, 0]
      );
      initCode = process.env.FACTORY_ADDRESS + factoryCalldata.slice(2);
    }

    // ── Build callData (what the smart account should do) ─
    // Encode SmartAccount.execute(target, value, data)
    const smartAccountInterface = new ethers.Interface(SMART_ACCOUNT_ABI);
    const callData = smartAccountInterface.encodeFunctionData('execute', [
      target,
      BigInt(value),
      data || '0x'
    ]);

    // ── Get gas estimates ─────────────────────────────────
    // In production, use a proper bundler API for gas estimation
    const gasLimits = await estimateUserOpGas(smartAccount, callData, initCode);

    // ── Build paymasterAndData ────────────────────────────
    const paymasterAndData = await buildPaymasterData(
      smartAccount,
      gasLimits,
      nonce
    );

    // ── Assemble UserOperation ────────────────────────────
    const userOperation = {
      sender: smartAccount,
      nonce: nonce.toString(),
      initCode,
      callData,
      callGasLimit: gasLimits.callGasLimit,
      verificationGasLimit: gasLimits.verificationGasLimit,
      preVerificationGas: gasLimits.preVerificationGas,
      maxFeePerGas: gasLimits.maxFeePerGas,
      maxPriorityFeePerGas: gasLimits.maxPriorityFeePerGas,
      paymasterAndData,
      signature: '0x'  // Will be filled in by the user
    };

    // ── Compute userOpHash ────────────────────────────────
    // This is what the user signs with MetaMask
    const userOpHash = await entryPoint.getUserOpHash(userOperation);

    res.json({
      userOperation: {
        ...userOperation,
        hash: userOpHash
      }
    });

  } catch (error) {
    console.error('Build UserOp error:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/transactions/submit
 *
 * Submits a signed UserOperation to the bundler.
 * At this point:
 * 1. User has signed the userOpHash
 * 2. Paymaster has already countersigned (in paymasterAndData)
 * 3. We submit to a bundler which will include it in a block
 */
app.post('/api/transactions/submit', requireAuth, async (req, res) => {
  const { userOperation } = req.body;

  try {
    // Submit to bundler API (Alchemy, Pimlico, or local bundler)
    const bundlerResponse = await axios.post(
      process.env.BUNDLER_RPC_URL,
      {
        jsonrpc: '2.0',
        method: 'eth_sendUserOperation',
        params: [userOperation, process.env.ENTRY_POINT_ADDRESS],
        id: 1
      },
      { headers: { 'Content-Type': 'application/json' } }
    );

    if (bundlerResponse.data.error) {
      throw new Error(bundlerResponse.data.error.message);
    }

    const userOpHash = bundlerResponse.data.result;

    res.json({ txHash: userOpHash });

  } catch (error) {
    console.error('Submit UserOp error:', error);
    res.status(500).json({ error: error.message });
  }
});

// ════════════════════════════════════════════════════════
//                     HELPERS
// ════════════════════════════════════════════════════════

/**
 * Builds the paymasterAndData field for a UserOperation.
 * This encodes: paymaster address + nonce + expiry + paymaster signature
 */
async function buildPaymasterData(smartAccount, gasLimits, userOpNonce) {
  const pmNonce = ethers.hexlify(crypto.randomBytes(32));
  const expiry = Math.floor(Date.now() / 1000) + (5 * 60); // 5 minute expiry

  // The paymaster signs the userOpHash + pmNonce + expiry
  // But we need the full userOp hash first... this is a simplification
  // In production: build full userOp, get hash from entryPoint, then sign
  const messageHash = ethers.keccak256(
    ethers.solidityPacked(
      ['string', 'bytes32', 'bytes32', 'uint256'],
      ['PAYMASTER_APPROVAL:', ethers.ZeroHash, pmNonce, expiry]
      // Note: In production, replace ethers.ZeroHash with actual userOpHash
    )
  );

  const pmSignature = await paymasterWallet.signMessage(ethers.getBytes(messageHash));

  // Encode: nonce (32 bytes) + expiry (32 bytes) + signature (65 bytes)
  const pmData = ethers.AbiCoder.defaultAbiCoder().encode(
    ['bytes32', 'uint256', 'bytes'],
    [pmNonce, expiry, pmSignature]
  );

  // paymasterAndData = paymaster address (20 bytes) + encoded data
  return process.env.PAYMASTER_ADDRESS + pmData.slice(2);
}

/**
 * Estimates gas limits for a UserOperation.
 * In production, call the bundler's eth_estimateUserOperationGas method.
 */
async function estimateUserOpGas(smartAccount, callData, initCode) {
  // For development: use generous fixed estimates
  // For production: call bundler RPC eth_estimateUserOperationGas

  const feeData = await provider.getFeeData();

  return {
    callGasLimit: '100000',
    verificationGasLimit: '150000',
    preVerificationGas: '50000',
    maxFeePerGas: feeData.maxFeePerGas?.toString() || '1000000000',
    maxPriorityFeePerGas: feeData.maxPriorityFeePerGas?.toString() || '100000000'
  };
}

// ════════════════════════════════════════════════════════
//                    MIDDLEWARE
// ════════════════════════════════════════════════════════

/**
 * JWT authentication middleware.
 * Verifies the session token issued after X OAuth.
 */
function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing authorization' });
  }

  const token = authHeader.slice(7);
  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    req.user = payload;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

// ── Minimal ABIs for backend use ─────────────────────────
const ENTRY_POINT_ABI = [
  "function getNonce(address sender, uint192 key) external view returns (uint256 nonce)",
  "function getUserOpHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
];

const FACTORY_ABI = [
  "function createAccount(address owner, address registry, bool requireXVerification, uint256 salt) external returns (address)",
  "function getAddress(address owner, address registry, bool requireXVerification, uint256 salt) external view returns (address)",
];

const SMART_ACCOUNT_ABI = [
  "function execute(address target, uint256 value, bytes data) external",
];

// ── Start server ─────────────────────────────────────────
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(`Backend server running on http://localhost:${PORT}`);
});
