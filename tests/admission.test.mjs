// Synthetic checks for the experimental admission cache. No network or credentials.
import assert from 'node:assert/strict';
import {AdmissionProvider, notaryExpirationMs} from '../muse_admission.mjs';

const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const fakeNotary = expiresAt => `header.signature.${encode({restrictions: [`timeout:${expiresAt}`]})}`;
const address = 'https://hatch.metaaivm.com';
const canonical = new URL(address).href;

// Notary expiration parsing
{
  const now = 1_700_000_000;
  assert.equal(notaryExpirationMs(fakeNotary(now + 300)), (now + 300) * 1000);
  assert.equal(notaryExpirationMs('not-a-token'), null);
  assert.equal(notaryExpirationMs(`a.${encode({restrictions: ['scope:read']})}.c`), null);
  assert.equal(notaryExpirationMs(`a.${encode({restrictions: ['timeout:soon']})}.c`), null);
}

// Cache, expiry, refresh and deduplication
{
  let calls = 0;
  let now = 1_700_000_000_000;
  const provider = new AdmissionProvider({
    now: () => now,
    fetchAuthenticated: async (url, options) => {
      calls += 1;
      const body = JSON.parse(options.body);
      assert.equal(url, 'https://muse.ai/api/hatch/token');
      assert.equal(body.vmAddress, canonical);
      return {
        ok: true,
        json: async () => ({token: `token-${calls}`, notary_token: fakeNotary(now / 1000 + 300)})
      };
    }
  });

  const first = await provider.get({vmAddress: address});
  assert.equal(first.token, 'token-1');
  assert.equal(calls, 1);

  const cached = await provider.get({vmAddress: address});
  assert.equal(cached.token, 'token-1');
  assert.equal(calls, 1);

  const concurrent = await Promise.all([
    provider.get({vmAddress: address}),
    provider.get({vmAddress: address})
  ]);
  assert.equal(concurrent[0].token, 'token-1');
  assert.equal(calls, 1);

  // Within 60 seconds of expiry the provider refreshes.
  now += (300 - 30) * 1000;
  const refreshed = await provider.get({vmAddress: address});
  assert.equal(refreshed.token, 'token-2');
  assert.equal(calls, 2);

  const forced = await provider.get({vmAddress: address, forceRefresh: true});
  assert.equal(forced.token, 'token-3');
  assert.equal(calls, 3);

  provider.clear();
  const afterClear = await provider.get({vmAddress: address});
  assert.equal(afterClear.token, 'token-4');
  assert.equal(calls, 4);
}

// Delegation tokens are endorsed before use and failures propagate
{
  const order = [];
  const provider = new AdmissionProvider({
    fetchAuthenticated: async () => ({
      ok: true,
      json: async () => ({token: 'admission', notary_token: 'delegation.payload.signature'})
    }),
    endorseDelegation: async input => {
      assert.equal(input.delegation, 'delegation.payload.signature');
      assert.equal(input.path, '/v1/noise');
      assert.equal(input.gatewayUrl, canonical);
      order.push('endorse');
      return 'endorsed-token';
    }
  });
  const value = await provider.get({vmAddress: address, vmName: 'vm-one'});
  assert.deepEqual(order, ['endorse']);
  assert.equal(value.notaryToken, 'endorsed-token');

  const missingEndorser = new AdmissionProvider({
    fetchAuthenticated: async () => ({
      ok: true,
      json: async () => ({token: 'admission', notary_token: 'delegation.payload.signature'})
    })
  });
  await assert.rejects(missingEndorser.get({vmAddress: address}), /endorser/);
}

// A target VM ID is preserved for admission and partitions the cache.
{
  const requests = [];
  const provider = new AdmissionProvider({
    fetchAuthenticated: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return {ok: true, json: async () => ({token: `admission-${requests.length}`})};
    }
  });
  const first = await provider.get({vmAddress: 'wss://hatch.metaaivm.com/', vmID: 'vm-one'});
  const second = await provider.get({vmAddress: 'wss://hatch.metaaivm.com/', vmID: 'vm-two'});
  assert.equal(first.token, 'admission-1');
  assert.equal(second.token, 'admission-2');
  assert.equal(requests[0].vmAddress, 'wss://hatch.metaaivm.com/?vm_id=vm-one');
  assert.equal(requests[1].vmAddress, 'wss://hatch.metaaivm.com/?vm_id=vm-two');
}

// Validation and error paths
{
  const provider = new AdmissionProvider({fetchAuthenticated: async () => ({ok: true, json: async () => ({token: 'x'})})});
  await assert.rejects(provider.get({vmAddress: 'https://user:pass@hatch.metaaivm.com'}), /Invalid gateway address/);
  await assert.rejects(provider.get({vmAddress: 'file:///etc/passwd'}), /Invalid gateway address/);
  await assert.rejects(provider.get({vmAddress: 'https://hatch.metaaivm.com/?auth_token=secret'}), /Invalid gateway address/);
  await assert.rejects(provider.get({vmAddress: 'https://hatch.metaaivm.com/?vm_id=one&vm_id=two'}), /Invalid gateway address/);
  await assert.rejects(provider.get({vmAddress: `https://hatch.metaaivm.com/?vm_id=${'x'.repeat(256)}`}), /Invalid gateway address/);
  await assert.rejects(provider.get({vmAddress: 'https://hatch.metaaivm.com/?vm_id=one', vmID: 'two'}), /Invalid gateway address/);

  const httpError = new AdmissionProvider({fetchAuthenticated: async () => ({ok: false, status: 503})});
  await assert.rejects(httpError.get({vmAddress: address}), /Admission request failed \(503\)/);

  const missingToken = new AdmissionProvider({fetchAuthenticated: async () => ({ok: true, json: async () => ({})})});
  await assert.rejects(missingToken.get({vmAddress: address}), /missing token/);
}

console.log('Admission provider cache, refresh, validation, and delegation checks passed.');
