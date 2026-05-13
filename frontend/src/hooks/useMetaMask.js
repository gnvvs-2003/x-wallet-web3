import { useState, useCallback, useEffect } from 'react';
import { ethers } from 'ethers';

/**
 * Custom hook for MetaMask wallet connection.
 */
export function useMetaMask() {
  const [account, setAccount]       = useState(null);
  const [chainId, setChainId]       = useState(null);
  const [provider, setProvider]     = useState(null);
  const [signer, setSigner]         = useState(null);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError]           = useState(null);

  const connect = useCallback(async () => {
    if (typeof window.ethereum === 'undefined') {
      setError('MetaMask is not installed. Please install it from metamask.io');
      return;
    }

    setIsConnecting(true);
    setError(null);

    try {
      const accounts = await window.ethereum.request({
        method: 'eth_requestAccounts'
      });

      if (accounts.length === 0) {
        throw new Error('No accounts returned. Did you approve the connection?');
      }

      const currentChainId = await window.ethereum.request({
        method: 'eth_chainId'
      });

      const ethersProvider = new ethers.BrowserProvider(window.ethereum);
      const ethersSigner = await ethersProvider.getSigner();

      setAccount(accounts[0]);
      setChainId(parseInt(currentChainId, 16));
      setProvider(ethersProvider);
      setSigner(ethersSigner);

    } catch (err) {
      setError(err.message || 'Connection failed');
    } finally {
      setIsConnecting(false);
    }
  }, []);

  const switchToSepolia = useCallback(async () => {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0xaa36a7' }]
      });
    } catch (switchError) {
      if (switchError.code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0xaa36a7',
            chainName: 'Sepolia Testnet',
            nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
            rpcUrls: ['https://rpc.sepolia.org'],
            blockExplorerUrls: ['https://sepolia.etherscan.io']
          }]
        });
      }
    }
  }, []);

  const signMessage = useCallback(async (message) => {
    if (!signer) throw new Error('Not connected');
    return await signer.signMessage(message);
  }, [signer]);

  const disconnect = useCallback(() => {
    setAccount(null);
    setChainId(null);
    setProvider(null);
    setSigner(null);
  }, []);

  useEffect(() => {
    if (typeof window.ethereum === 'undefined') return;

    const handleAccountsChanged = (accounts) => {
      if (accounts.length === 0) {
        disconnect();
      } else {
        setAccount(accounts[0]);
      }
    };

    const handleChainChanged = (chainId) => {
      setChainId(parseInt(chainId, 16));
      window.location.reload();
    };

    window.ethereum.on('accountsChanged', handleAccountsChanged);
    window.ethereum.on('chainChanged', handleChainChanged);

    return () => {
      window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
      window.ethereum.removeListener('chainChanged', handleChainChanged);
    };
  }, [disconnect]);

  return {
    account,
    chainId,
    provider,
    signer,
    isConnecting,
    error,
    connect,
    disconnect,
    switchToSepolia,
    signMessage,
    isConnected: !!account,
    isOnSepolia: chainId === 11155111
  };
}
