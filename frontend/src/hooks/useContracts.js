import { useMemo } from 'react';
import { ethers } from 'ethers';

const REGISTRY_ABI = [
  "function linkUsername(string username, string xUserId, bytes32 nonce, uint256 expiry, bytes backendSig) external",
  "function unlinkUsername() external",
  "function getWalletByUsername(string username) external view returns (address)",
  "function getUsernameByWallet(address wallet) external view returns (string)",
  "function isVerified(address wallet) external view returns (bool)",
  "function verifiedAt(address wallet) external view returns (uint256)",
  "event UsernameLinked(address indexed wallet, string username, uint256 timestamp)",
];

const FACTORY_ABI = [
  "function createAccount(address owner, address registry, bool requireXVerification, uint256 salt) external returns (address)",
  "function getAddress(address owner, address registry, bool requireXVerification, uint256 salt) external view returns (address)",
];

const SMART_ACCOUNT_ABI = [
  "function execute(address target, uint256 value, bytes data) external",
  "function getLinkedUsername() external view returns (string)",
  "function hasXVerification() external view returns (bool)",
  "function getNonce() external view returns (uint256)",
  "function owner() external view returns (address)",
];

export function useContracts(signer, provider) {
  const REGISTRY_ADDRESS  = import.meta.env.VITE_REGISTRY_ADDRESS;
  const FACTORY_ADDRESS   = import.meta.env.VITE_FACTORY_ADDRESS;
  const PAYMASTER_ADDRESS = import.meta.env.VITE_PAYMASTER_ADDRESS;

  const registry = useMemo(() => {
    if (!signer || !REGISTRY_ADDRESS) return null;
    return new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, signer);
  }, [signer, REGISTRY_ADDRESS]);

  const factory = useMemo(() => {
    if (!provider || !FACTORY_ADDRESS) return null;
    return new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, provider);
  }, [provider, FACTORY_ADDRESS]);

  const getSmartAccount = (address) => {
    if (!signer || !address) return null;
    return new ethers.Contract(address, SMART_ACCOUNT_ABI, signer);
  };

  return { registry, factory, getSmartAccount, PAYMASTER_ADDRESS };
}
