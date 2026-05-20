import http from 'node:http';
import crypto from 'node:crypto';
import { AddressInfo } from 'node:net';
import { google, gmail_v1 } from 'googleapis';
import { OAuth2Client } from 'google-auth-library';
import open from 'open';
import { log } from '../../log.js';
import { getToken, setToken } from '../../keychain.js';

export const OAuthScopes = [
  'https://www.googleapis.com/auth/gmail.modify',
  'https://www.googleapis.com/auth/gmail.send',
];

export type ClientCredentials = { client_id: string; client_secret: string };

export function loadClientCredentials(): ClientCredentials | null {
  const client_id = process.env.GEO_CLAW_GOOGLE_CLIENT_ID;
  const client_secret = process.env.GEO_CLAW_GOOGLE_CLIENT_SECRET;
  if (!client_id || !client_secret) {
    log.error(
      'Gmail OAuth client credentials missing. Set GEO_CLAW_GOOGLE_CLIENT_ID and GEO_CLAW_GOOGLE_CLIENT_SECRET (Desktop OAuth client from Google Cloud Console). See README.',
    );
    return null;
  }
  return { client_id, client_secret };
}

function attachTokenPersistence(client: OAuth2Client): void {
  client.on('tokens', (tokens) => {
    void (async () => {
      try {
        if (tokens.refresh_token) {
          await setToken('gmail-refresh', tokens.refresh_token);
        }
        if (tokens.access_token) {
          await setToken('gmail-access', tokens.access_token);
        }
      } catch (err) {
        log.warn({ err: (err as Error).message }, 'failed to persist refreshed gmail tokens');
      }
    })();
  });
}

const OAUTH_TIMEOUT_MS = 5 * 60_000;

export async function authorizeInteractive(): Promise<void> {
  const creds = loadClientCredentials();
  if (!creds) {
    throw new Error('missing google oauth client credentials');
  }

  const csrfState = crypto.randomBytes(16).toString('hex');
  let client: OAuth2Client | null = null;

  await new Promise<void>((resolve, reject) => {
    let settled = false;
    let timeoutHandle: NodeJS.Timeout | null = null;

    const finish = (err?: Error) => {
      if (settled) return;
      settled = true;
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
        timeoutHandle = null;
      }
      try {
        server.close();
      } catch {}
      if (err) reject(err);
      else resolve();
    };

    const server = http.createServer((req, res) => {
      try {
        if (!req.url) {
          res.writeHead(400);
          res.end('bad request');
          return;
        }
        const url = new URL(req.url, `http://127.0.0.1`);
        if (url.pathname !== '/oauth/callback') {
          res.writeHead(404);
          res.end('not found');
          return;
        }
        const code = url.searchParams.get('code');
        const errParam = url.searchParams.get('error');
        const stateParam = url.searchParams.get('state');
        if (errParam) {
          res.writeHead(400, { 'Content-Type': 'text/html; charset=utf-8' });
          res.end(`<html><body><h1>Authorization failed</h1><p>${errParam}</p></body></html>`);
          finish(new Error(`oauth error: ${errParam}`));
          return;
        }
        if (stateParam !== csrfState) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end('state mismatch');
          finish(new Error('oauth state mismatch'));
          return;
        }
        if (!code) {
          res.writeHead(400);
          res.end('missing code');
          return;
        }
        if (!client) {
          res.writeHead(500);
          res.end('client not initialized');
          finish(new Error('oauth client not initialized'));
          return;
        }

        const activeClient = client;
        void (async () => {
          try {
            const { tokens } = await activeClient.getToken(code);
            if (tokens.refresh_token) {
              await setToken('gmail-refresh', tokens.refresh_token);
            } else {
              log.warn('OAuth response did not include refresh_token; user may need to revoke prior consent');
            }
            if (tokens.access_token) {
              await setToken('gmail-access', tokens.access_token);
            }
            activeClient.setCredentials(tokens);
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(
              '<!doctype html><html><head><title>geo-claw</title><style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#0b0b0b;color:#eaeaea}main{text-align:center;padding:2rem;border:1px solid #222;border-radius:12px;background:#111}h1{margin:0 0 .5rem 0;font-size:1.4rem}p{margin:0;color:#aaa}</style></head><body><main><h1>Authorized</h1><p>You can close this tab.</p></main></body></html>',
            );
            finish();
          } catch (err) {
            res.writeHead(500, { 'Content-Type': 'text/plain' });
            res.end('token exchange failed');
            finish(err as Error);
          }
        })();
      } catch (err) {
        finish(err as Error);
      }
    });

    server.on('error', (err) => finish(err));

    server.listen(0, '127.0.0.1', () => {
      const addr = server.address() as AddressInfo;
      const redirectUri = `http://127.0.0.1:${addr.port}/oauth/callback`;
      client = new google.auth.OAuth2({
        clientId: creds.client_id,
        clientSecret: creds.client_secret,
        redirectUri,
      });
      attachTokenPersistence(client);
      const authUrl = client.generateAuthUrl({
        access_type: 'offline',
        prompt: 'consent',
        scope: OAuthScopes,
        state: csrfState,
      });
      log.info({ redirectUri }, 'gmail oauth: opening browser');
      open(authUrl).catch((err: unknown) => {
        log.warn({ err: (err as Error).message, authUrl }, 'failed to open browser; visit URL manually');
      });
    });

    timeoutHandle = setTimeout(() => {
      finish(new Error('oauth timed out waiting for callback'));
    }, OAUTH_TIMEOUT_MS);
  });
}

export async function getAuthorizedClient(): Promise<gmail_v1.Gmail | null> {
  const creds = loadClientCredentials();
  if (!creds) return null;
  const refreshToken = await getToken('gmail-refresh');
  if (!refreshToken) return null;
  const client = new google.auth.OAuth2({
    clientId: creds.client_id,
    clientSecret: creds.client_secret,
  });
  const accessToken = await getToken('gmail-access');
  client.setCredentials({
    refresh_token: refreshToken,
    ...(accessToken ? { access_token: accessToken } : {}),
  });
  attachTokenPersistence(client);
  return google.gmail({ version: 'v1', auth: client });
}
