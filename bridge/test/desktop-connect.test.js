import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCipheriv, createHash, createPublicKey, generateKeyPairSync, randomBytes, verify } from 'node:crypto';
import { decryptDesktop, relayTargets, proof } from '../src/desktop-connect.js';

test('desktop catalog decryption authenticates the encrypted contents', () => {
  const key = randomBytes(32), iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([Buffer.from('v10'), iv, cipher.update('{"targets":[]}'), cipher.final(), cipher.getAuthTag()]);
  assert.equal(decryptDesktop(encrypted.toString('base64'), key), '{"targets":[]}');
  encrypted[16] ^= 1;
  assert.throws(() => decryptDesktop(encrypted.toString('base64'), key));
});

test('desktop discovery excludes disabled machines and non-relay routes', () => {
  assert.deepEqual(relayTargets({ targets: [
    { _tag: 'RelayConnectionTarget', environmentId: 'a' },
    { _tag: 'RelayConnectionTarget', environmentId: 'b' },
    { _tag: 'BearerConnectionTarget', environmentId: 'c' },
  ], disabledEnvironmentIds: ['b'] }), [{ _tag: 'RelayConnectionTarget', environmentId: 'a' }]);
});

test('DPoP proof binds its signature to the method, canonical URL and access token', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const key = privateKey.export({ format: 'jwk' });
  const jwt = proof(key, 'GET', 'https://example.com/ws?ticket=secret#fragment', 'token');
  const [header, payload, signature] = jwt.split('.');
  const h = JSON.parse(Buffer.from(header, 'base64url'));
  const p = JSON.parse(Buffer.from(payload, 'base64url'));
  assert.equal(h.jwk.d, undefined);
  assert.equal(p.htm, 'GET');
  assert.equal(p.htu, 'https://example.com/ws');
  assert.equal(p.ath, createHash('sha256').update('token').digest('base64url'));
  assert.ok(verify('sha256', Buffer.from(`${header}.${payload}`), { key: createPublicKey({ key: h.jwk, format: 'jwk' }), dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
  assert.notEqual(jwt, proof(key, 'GET', 'https://example.com/ws', 'token'));
});
