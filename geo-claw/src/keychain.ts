import keytar from 'keytar';
import { KEYCHAIN_SERVICE } from './config.js';

export type KeychainAccount =
  | 'mcp'
  | 'gmail-refresh'
  | 'gmail-access'
  | 'telegram-bot-token'
  | 'telegram-owner-id';

export function getToken(account: KeychainAccount): Promise<string | null> {
  return keytar.getPassword(KEYCHAIN_SERVICE, account);
}

export function setToken(account: KeychainAccount, value: string): Promise<void> {
  return keytar.setPassword(KEYCHAIN_SERVICE, account, value);
}

export function deleteToken(account: KeychainAccount): Promise<boolean> {
  return keytar.deletePassword(KEYCHAIN_SERVICE, account);
}
