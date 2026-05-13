import { useState, useCallback, useEffect } from "react";
import { ethers } from "ethers";
/**
 * @author gnvvs-2003
 * @summary Custom hook for metamask wallet connection
 */
export function useMetamask() {
    // ═══════════════════════════ STATE VARIABLES ═══════════════════════════
    const [account, setAccount] = useState(null);
    const [chainId, setChainId] = useState(null);
    const [provider, setProvider] = useState(null);
    const [signer, setSigner] = useState(null);
    const [isConnected, setIsConnected] = useState(false);
    const [error, setError] = useState(null);
    // ═══════════════════════════ WALLET CONNECTION ═══════════════════════════
    const connect = useCallback(
        async () => {
            // Check if Metamask is installed or not
            if (typeof (window.ethereum == 'undefined')) {
                setError('Metamask is not installed.Please install it from metamask.io');
                return;
            }
            setIsConnected(true);
            setError(null);
            try {
                // Request wallet connection
                const accounts = await window.ethereum.request({
                    method: 'eth_requestAccounts'
                });
                if (accounts.length === 0) {
                    throw new Error('No accounts Approved connection');
                }
                const currentChainId = await window.ethereum.request({
                    method: 'eth_chainId'
                });
                // ═════════════════════════ PROVIDER AND SIGNER ═════════════════════════
                const ethersProvider = new ethers.BrowserProvider(window.ethereum);
                const ethersSigner = await ethersProvider.getSigner();
                // ═════════════════════════ SET STATE VARIABLES ═════════════════════════
                setAccount(accounts[0]);
                setChainId(parseInt(currentChainId, 16));
                setProvider(ethersProvider);
                setSigner(ethersSigner);
            } catch (err) {
                setError(err.message || 'Connection failed');
            } finally {
                setIsConnected(false);
            }
        }, []
    );
}