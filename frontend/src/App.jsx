import { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { useMetaMask } from './hooks/useMetaMask';
import { useContracts } from './hooks/useContracts';
import './App.css';

// ──────────────────────────────────────────────────────────
//              PKCE HELPER FUNCTIONS
// ──────────────────────────────────────────────────────────

function generateCodeVerifier() {
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  return btoa(String.fromCharCode(...array))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

async function generateCodeChallenge(verifier) {
  const encoder = new TextEncoder();
  const data = encoder.encode(verifier);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function generateState() {
  const array = new Uint8Array(16);
  crypto.getRandomValues(array);
  return btoa(String.fromCharCode(...array))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

export default function App() {
  const {
    account, chainId, provider, signer, isConnecting, error: walletError,
    connect, disconnect, switchToSepolia, signMessage, isConnected, isOnSepolia
  } = useMetaMask();

  const { registry, factory, getSmartAccount, PAYMASTER_ADDRESS } = useContracts(signer, provider);

  // ── State ─────────────────────────────────────────────
  const [xUsername, setXUsername]               = useState(null);
  const [xAccessToken, setXAccessToken]         = useState(null);
  const [smartAccountAddress, setSmartAccountAddress] = useState(null);
  const [isLinked, setIsLinked]                 = useState(false);
  const [linkStatus, setLinkStatus]             = useState('');
  const [txHash, setTxHash]                     = useState('');
  const [isSending, setIsSending]               = useState(false);
  const [targetAddress, setTargetAddress]       = useState('');
  const [sendAmount, setSendAmount]             = useState('0.001');

  const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001';

  // ── Check X OAuth callback on mount ───────────────────
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const state = params.get('state');

    if (code) {
      handleXCallback(code, state);
      window.history.replaceState({}, document.title, '/');
    }
  }, []);

  // ── Check existing link when wallet connects ───────────
  useEffect(() => {
    if (account && registry) {
      checkExistingLink();
    }
  }, [account, registry]);

  // ── Compute Smart Account Address ─────────────────────
  useEffect(() => {
    if (account && factory) {
      computeSmartAccountAddress();
    }
  }, [account, factory]);

  const checkExistingLink = async () => {
    try {
      const username = await registry.getUsernameByWallet(account);
      if (username && username !== "") {
        setIsLinked(true);
        setXUsername(username);
      }
    } catch (err) {
      console.error('Error checking link:', err);
    }
  };

  const computeSmartAccountAddress = async () => {
    try {
      const addr = await factory.getAddress(
        account,
        import.meta.env.VITE_REGISTRY_ADDRESS,
        false,
        0
      );
      setSmartAccountAddress(addr);
    } catch (err) {
      console.error('Error computing smart account address:', err);
    }
  };

  const loginWithX = async () => {
    const codeVerifier = generateCodeVerifier();
    const codeChallenge = await generateCodeChallenge(codeVerifier);
    const state = generateState();

    sessionStorage.setItem('pkce_verifier', codeVerifier);
    sessionStorage.setItem('oauth_state', state);

    const params = new URLSearchParams({
      response_type: 'code',
      client_id: import.meta.env.VITE_TWITTER_CLIENT_ID,
      redirect_uri: import.meta.env.VITE_OAUTH_CALLBACK_URL,
      scope: 'users.read tweet.read offline.access',
      state: state,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256'
    });

    window.location.href = `https://twitter.com/i/oauth2/authorize?${params.toString()}`;
  };

  const handleXCallback = async (code, state) => {
    const savedState = sessionStorage.getItem('oauth_state');
    if (state !== savedState) {
      console.error('OAuth state mismatch');
      return;
    }

    const codeVerifier = sessionStorage.getItem('pkce_verifier');

    try {
      const response = await fetch(`${API_URL}/api/auth/x/callback`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, codeVerifier })
      });

      if (!response.ok) throw new Error('Backend auth exchange failed');

      const data = await response.json();
      setXUsername(data.username);
      setXAccessToken(data.accessToken);

      sessionStorage.removeItem('pkce_verifier');
      sessionStorage.removeItem('oauth_state');

    } catch (err) {
      console.error('X callback failed:', err);
      setLinkStatus('X login failed: ' + err.message);
    }
  };

  const linkXToWallet = async () => {
    if (!xUsername || !account || !registry) return;
    setLinkStatus('Requesting backend authorization...');

    try {
      const response = await fetch(`${API_URL}/api/auth/link`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${xAccessToken}`
        },
        body: JSON.stringify({ walletAddress: account })
      });

      if (!response.ok) {
        const err = await response.json();
        throw new Error(err.error || 'Backend authorization failed');
      }

      const { username, xUserId, nonce, expiry, backendSignature } = await response.json();

      setLinkStatus('Please confirm the transaction in MetaMask...');

      const tx = await registry.linkUsername(
        username,
        xUserId,
        nonce,
        expiry,
        backendSignature
      );

      setLinkStatus(`Transaction sent! Waiting for confirmation...`);
      const receipt = await tx.wait(1);

      if (receipt.status === 1) {
        setIsLinked(true);
        setLinkStatus('✅ Successfully linked @' + username + ' to your wallet!');
      } else {
        setLinkStatus('❌ Transaction failed on-chain');
      }
    } catch (err) {
      setLinkStatus('❌ Error: ' + (err.reason || err.message));
    }
  };

  const sendGaslessTransaction = async () => {
    if (!smartAccountAddress || !targetAddress) return;
    setIsSending(true);
    setTxHash('');

    try {
      const code = await provider.getCode(smartAccountAddress);
      const isDeployed = code !== '0x';

      const response = await fetch(`${API_URL}/api/transactions/build`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${xAccessToken}`
        },
        body: JSON.stringify({
          smartAccount: smartAccountAddress,
          owner: account,
          target: targetAddress,
          value: ethers.parseEther(sendAmount).toString(),
          data: '0x',
          isDeployed,
          registryAddress: import.meta.env.VITE_REGISTRY_ADDRESS
        })
      });

      if (!response.ok) {
          const err = await response.json();
          throw new Error(err.error || 'Failed to build transaction');
      }

      const { userOperation } = await response.json();
      const userOpHash = userOperation.hash;
      const signature = await signMessage(ethers.getBytes(userOpHash));

      const submitResponse = await fetch(`${API_URL}/api/transactions/submit`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${xAccessToken}`
        },
        body: JSON.stringify({
          userOperation: {
            ...userOperation,
            signature
          }
        })
      });

      if (!submitResponse.ok) {
          const err = await submitResponse.json();
          throw new Error(err.error || 'Failed to submit transaction');
      }

      const { txHash: hash } = await submitResponse.json();
      setTxHash(hash);

    } catch (err) {
      console.error('Transaction failed:', err);
      setTxHash('ERROR: ' + err.message);
    } finally {
      setIsSending(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-950 text-white p-8 font-sans">
      <div className="max-w-2xl mx-auto space-y-8">
        <header className="text-center">
          <h1 className="text-5xl font-extrabold bg-clip-text text-transparent bg-gradient-to-r from-blue-400 to-purple-600">X-Wallet</h1>
          <p className="text-gray-400 mt-4 text-lg">Identity-linked Gasless Wallets</p>
        </header>

        {/* Step 1: Connect Wallet */}
        <section className="bg-gray-900/50 backdrop-blur-md rounded-2xl p-8 border border-gray-800 shadow-xl">
          <h2 className="text-2xl font-bold mb-6 flex items-center gap-3">
            <span className="flex items-center justify-center w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 text-sm">1</span>
            Connect MetaMask
          </h2>

          {!isConnected ? (
            <button
              onClick={connect}
              disabled={isConnecting}
              className="w-full bg-gradient-to-r from-orange-500 to-orange-600 hover:from-orange-600 hover:to-orange-700 text-white font-bold py-4 px-6 rounded-xl transition duration-200 transform hover:scale-[1.02] active:scale-[0.98] disabled:opacity-50 shadow-lg shadow-orange-500/20"
            >
              {isConnecting ? 'Connecting...' : '🦊 Connect MetaMask'}
            </button>
          ) : (
            <div className="space-y-4">
              <div className="flex items-center justify-between p-4 bg-gray-800/50 rounded-xl border border-gray-700">
                <div className="flex items-center gap-3">
                  <div className="w-3 h-3 rounded-full bg-green-500 animate-pulse"></div>
                  <span className="text-green-400 font-medium">Connected</span>
                </div>
                <button
                  onClick={disconnect}
                  className="text-sm text-gray-500 hover:text-red-400 transition-colors"
                >
                  Disconnect
                </button>
              </div>
              <p className="text-sm text-gray-400 font-mono break-all bg-black/30 p-3 rounded-lg">
                {account}
              </p>
              {!isOnSepolia && (
                <button
                  onClick={switchToSepolia}
                  className="w-full bg-yellow-500/10 hover:bg-yellow-500/20 text-yellow-500 border border-yellow-500/30 py-3 px-4 rounded-xl text-sm font-semibold transition"
                >
                  ⚠️ Switch to Sepolia Testnet
                </button>
              )}
              {smartAccountAddress && (
                <div className="p-4 bg-blue-500/5 rounded-xl border border-blue-500/10">
                  <p className="text-xs text-gray-500 mb-1 uppercase tracking-wider font-bold">Your Smart Account</p>
                  <p className="text-sm font-mono text-blue-400 break-all">
                    {smartAccountAddress}
                  </p>
                </div>
              )}
            </div>
          )}

          {walletError && (
            <p className="mt-4 p-3 bg-red-500/10 text-red-400 text-sm rounded-lg border border-red-500/20">{walletError}</p>
          )}
        </section>

        {/* Step 2: Login with X */}
        {isConnected && isOnSepolia && (
          <section className="bg-gray-900/50 backdrop-blur-md rounded-2xl p-8 border border-gray-800 shadow-xl animate-in fade-in slide-in-from-bottom-4 duration-500">
            <h2 className="text-2xl font-bold mb-6 flex items-center gap-3">
              <span className="flex items-center justify-center w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 text-sm">2</span>
              Login with X
            </h2>

            {!xUsername ? (
              <button
                onClick={loginWithX}
                className="w-full bg-black hover:bg-gray-900 border border-gray-700 text-white font-bold py-4 px-6 rounded-xl transition duration-200 transform hover:scale-[1.02] flex items-center justify-center gap-4 shadow-lg"
              >
                <svg className="w-5 h-5 fill-current" viewBox="0 0 24 24"><path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/></svg>
                Sign in with X
              </button>
            ) : (
              <div className="flex items-center gap-4 p-4 bg-green-500/5 rounded-xl border border-green-500/10">
                <div className="w-10 h-10 rounded-full bg-green-500/20 flex items-center justify-center text-green-400">
                  <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M5 13l4 4L19 7"/></svg>
                </div>
                <div>
                  <p className="text-sm text-gray-500">Authenticated as</p>
                  <p className="text-lg font-bold text-white">@{xUsername}</p>
                </div>
              </div>
            )}
          </section>
        )}

        {/* Step 3: Link X to Wallet */}
        {xUsername && !isLinked && (
          <section className="bg-gray-900/50 backdrop-blur-md rounded-2xl p-8 border border-gray-800 shadow-xl animate-in fade-in slide-in-from-bottom-4 duration-500">
            <h2 className="text-2xl font-bold mb-6 flex items-center gap-3">
              <span className="flex items-center justify-center w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 text-sm">3</span>
              Link Account On-Chain
            </h2>

            <p className="text-gray-400 mb-6 leading-relaxed">
              Finalize the connection between <strong className="text-white">@{xUsername}</strong> and your wallet. This requires a one-time blockchain transaction.
            </p>

            <button
              onClick={linkXToWallet}
              className="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-4 px-6 rounded-xl transition duration-200 transform hover:scale-[1.02] shadow-lg shadow-blue-500/20"
            >
              🔗 Link @{xUsername} On-Chain
            </button>

            {linkStatus && (
              <p className="mt-4 text-sm text-blue-300 p-3 bg-blue-500/5 rounded-lg border border-blue-500/10">{linkStatus}</p>
            )}
          </section>
        )}

        {/* Step 4: Gasless Transactions */}
        {isLinked && (
          <section className="bg-gray-900/50 backdrop-blur-md rounded-2xl p-8 border border-gray-800 shadow-xl animate-in fade-in slide-in-from-bottom-4 duration-500">
            <h2 className="text-2xl font-bold mb-6 flex items-center gap-3">
              <span className="flex items-center justify-center w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 text-sm">4</span>
              Gasless Transaction
            </h2>

            <div className="space-y-6">
              <div>
                <label className="text-xs font-bold text-gray-500 uppercase tracking-widest block mb-2">Recipient Address</label>
                <input
                  type="text"
                  value={targetAddress}
                  onChange={e => setTargetAddress(e.target.value)}
                  placeholder="0x..."
                  className="w-full bg-black/50 border border-gray-800 focus:border-blue-500/50 rounded-xl px-4 py-4 text-white font-mono text-sm transition-colors outline-none"
                />
              </div>

              <div>
                <label className="text-xs font-bold text-gray-500 uppercase tracking-widest block mb-2">Amount (ETH)</label>
                <input
                  type="number"
                  value={sendAmount}
                  onChange={e => setSendAmount(e.target.value)}
                  step="0.001"
                  min="0"
                  className="w-full bg-black/50 border border-gray-800 focus:border-blue-500/50 rounded-xl px-4 py-4 text-white transition-colors outline-none"
                />
              </div>

              <button
                onClick={sendGaslessTransaction}
                disabled={isSending || !targetAddress}
                className="w-full bg-gradient-to-r from-green-500 to-emerald-600 hover:from-green-600 hover:to-emerald-700 text-white font-bold py-4 px-6 rounded-xl transition duration-200 transform hover:scale-[1.02] disabled:opacity-50 shadow-lg shadow-green-500/20"
              >
                {isSending ? (
                  <span className="flex items-center justify-center gap-2">
                    <svg className="animate-spin h-5 w-5" viewBox="0 0 24 24"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none"></circle><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg>
                    Sending...
                  </span>
                ) : '⛽ Send Gasless Transaction'}
              </button>

              {txHash && (
                <div className="p-4 bg-gray-800/50 rounded-xl border border-gray-700">
                  <p className="text-xs text-gray-500 mb-2 uppercase font-bold">Status</p>
                  {txHash.startsWith('ERROR') ? (
                    <p className="text-red-400 text-sm font-medium">{txHash}</p>
                  ) : (
                    <div className="flex items-center justify-between">
                      <span className="text-green-400 text-sm font-medium">Success!</span>
                      <a
                        href={`https://sepolia.etherscan.io/tx/${txHash}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-blue-400 text-sm hover:underline flex items-center gap-1"
                      >
                        View on Etherscan
                        <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
                      </a>
                    </div>
                  )}
                </div>
              )}

              <div className="p-4 bg-blue-500/5 rounded-xl border border-blue-500/10 flex gap-3">
                <div className="text-blue-400 flex-shrink-0">
                  <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                </div>
                <p className="text-sm text-blue-300 leading-relaxed">
                  Gas fees are fully sponsored. You don't need any ETH in your wallet to perform this action.
                </p>
              </div>
            </div>
          </section>
        )}
      </div>
    </div>
  );
}
