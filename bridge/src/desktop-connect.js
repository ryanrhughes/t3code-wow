// Windows desktop T3 Connect connections. Keep desktop credentials encrypted on
// disk, and use a separate proof key and narrowly scoped session for the bridge.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createDecipheriv, createHash, createPrivateKey, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { CONFIG_DIR } from './auth.js';
import { t3Home, PROTOCOL } from './t3.js';

export function decryptDesktop(value, key) {
  const bytes = Buffer.from(value, 'base64');
  if (bytes.subarray(0, 3).toString() !== 'v10') throw new Error('Unsupported desktop encryption format');
  const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(3, 15));
  decipher.setAuthTag(bytes.subarray(-16));
  return Buffer.concat([decipher.update(bytes.subarray(15, -16)), decipher.final()]).toString();
}

function desktopDecryptor() {
  const script = `Add-Type -AssemblyName System.Security; $s=Get-Content -LiteralPath "$env:APPDATA\\t3code-v2\\Local State" -Raw | ConvertFrom-Json; $b=[Convert]::FromBase64String($s.os_crypt.encrypted_key); [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Unprotect($b[5..($b.Length-1)],$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))`;
  const key = Buffer.from(execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true, encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'] }).trim(), 'base64');
  return (value) => decryptDesktop(value, key);
}

export function relayTargets(catalog) {
  return (catalog.targets || []).filter((t) => t._tag === 'RelayConnectionTarget' && !(catalog.disabledEnvironmentIds || []).includes(t.environmentId));
}

export function desktopTargets() {
  if (process.platform !== 'win32') return [];
  const file = path.join(t3Home(), 'userdata', 'connection-catalog.json');
  if (!fs.existsSync(file)) return [];
  return relayTargets(JSON.parse(desktopDecryptor()(JSON.parse(fs.readFileSync(file, 'utf8')).encryptedCatalog)));
}

const encode = (v) => Buffer.from(JSON.stringify(v)).toString('base64url');
const hash = (v) => createHash('sha256').update(v).digest('base64url');

export function proof(key, method, address, accessToken) {
  const { kty, crv, x, y } = key;
  const url = new URL(address);
  url.search = ''; url.hash = '';
  const input = `${encode({ typ: 'dpop+jwt', alg: 'ES256', jwk: { kty, crv, x, y } })}.${encode({ htm: method, htu: url.toString(), jti: randomUUID(), iat: Math.floor(Date.now() / 1000), ...(accessToken ? { ath: hash(accessToken) } : {}) })}`;
  return `${input}.${sign('sha256', Buffer.from(input), { key: createPrivateKey({ key, format: 'jwk' }), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(20000) });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new Error(`T3 Connect ${new URL(url).pathname}: HTTP ${response.status} (${error.reason || error._tag || error.error || 'request failed'})`);
  }
  return response.json();
}

export class DesktopConnect {
  constructor(target) {
    this.target = target;
    this.session = null;
    const file = path.join(CONFIG_DIR, 'connect-proof-key.json');
    fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    if (!fs.existsSync(file)) fs.writeFileSync(file, JSON.stringify(generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ format: 'jwk' })), { mode: 0o600, flag: 'wx' });
    this.key = JSON.parse(fs.readFileSync(file, 'utf8'));
  }

  async authorize() {
    if (this.session && this.session.expires > Date.now() + 60000) return this.session;
    const saved = JSON.parse(fs.readFileSync(path.join(t3Home(), 'userdata', 'clerk', 'clerk-tokens.json'), 'utf8')).__clerk_client_jwt;
    if (!saved?.startsWith('enc:')) throw new Error('Sign into T3 Connect in the desktop app first');
    const clientToken = desktopDecryptor()(saved.slice(4));
    const headers = { authorization: `Bearer ${clientToken}` };
    const client = await jsonRequest('https://clerk.t3.codes/v1/client?_is_native=1', { headers });
    const sessionId = client.response?.last_active_session_id;
    if (!sessionId) throw new Error('Sign into T3 Connect in the desktop app first');
    const clerk = await jsonRequest(`https://clerk.t3.codes/v1/client/sessions/${encodeURIComponent(sessionId)}/tokens/t3-relay?_is_native=1`, { method: 'POST', headers });
    const jwt = clerk.jwt || clerk.response?.jwt;
    if (!jwt) throw new Error('T3 Connect sign-in did not return a session');
    const relay = 'https://relay.t3.codes';
    const exchangeUrl = `${relay}/v1/client/dpop-token`;
    const exchanged = await jsonRequest(exchangeUrl, {
      method: 'POST', headers: { dpop: proof(this.key, 'POST', exchangeUrl) },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange', subject_token: jwt, subject_token_type: 'urn:ietf:params:oauth:token-type:jwt', requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', resource: relay, scope: 'environment:connect', client_id: 't3-web' }),
    });
    const connectUrl = `${relay}/v1/environments/${encodeURIComponent(this.target.environmentId)}/connect`;
    const { kty, crv, x, y } = this.key;
    const bootstrap = await jsonRequest(connectUrl, {
      method: 'POST', headers: { authorization: `DPoP ${exchanged.access_token}`, dpop: proof(this.key, 'POST', connectUrl, exchanged.access_token), 'content-type': 'application/json' },
      body: JSON.stringify({ clientKeyThumbprint: hash(JSON.stringify({ crv, kty, x, y })) }),
    });
    if (bootstrap.environmentId !== this.target.environmentId) throw new Error('T3 Connect returned a different machine');
    const tokenUrl = new URL('/oauth/token', bootstrap.endpoint.httpBaseUrl).href;
    const access = await jsonRequest(tokenUrl, {
      method: 'POST', headers: { dpop: proof(this.key, 'POST', tokenUrl) },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange', subject_token: bootstrap.credential, subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap', requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', scope: 'orchestration:read orchestration:operate' }),
    });
    this.session = { token: access.access_token, endpoint: bootstrap.endpoint, expires: Date.now() + access.expires_in * 1000 };
    return this.session;
  }

  async headers(method, url) {
    const session = await this.authorize();
    return { authorization: `DPoP ${session.token}`, dpop: proof(this.key, method, url, session.token) };
  }

  async socketUrl() {
    const session = await this.authorize();
    const ticketUrl = new URL('/api/auth/websocket-ticket/rpc', session.endpoint.httpBaseUrl).href;
    const { ticket } = await jsonRequest(ticketUrl, { method: 'POST', headers: await this.headers('POST', ticketUrl) });
    const url = new URL(session.endpoint.wsBaseUrl);
    const httpUrl = new URL(url); httpUrl.protocol = url.protocol === 'wss:' ? 'https:' : 'http:';
    url.searchParams.set('wsTicket', ticket);
    url.searchParams.set('dpop', proof(this.key, 'GET', httpUrl.href, ticket));
    url.searchParams.set('orchestrationProtocol', String(PROTOCOL));
    return url;
  }
}
