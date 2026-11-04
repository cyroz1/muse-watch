// Browser-session admission provider. The caller supplies an authenticated fetch
// implementation and, where needed, a delegation endorser. Never log tokens.
const MUSE_TOKEN_ENDPOINT = 'https://muse.ai/api/hatch/token';

export function notaryExpirationMs(token) {
  if (typeof token !== 'string') return null;
  try {
    const part = token.split('.')[2];
    if (!part) return null;
    const payload = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    if (!Array.isArray(payload.restrictions)) return null;
    for (const item of payload.restrictions) {
      if (typeof item !== 'string' || !item.startsWith('timeout:')) continue;
      const seconds = Number(item.slice('timeout:'.length).trim());
      return Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : null;
    }
  } catch { /* malformed or unrecognized token; caller decides how to proceed */ }
  return null;
}

export class AdmissionProvider {
  constructor({fetchAuthenticated, endorseDelegation, now = Date.now}) {
    if (typeof fetchAuthenticated !== 'function') throw new TypeError('An authenticated fetch implementation is required');
    this.fetchAuthenticated = fetchAuthenticated;
    this.endorseDelegation = endorseDelegation;
    this.now = now;
    this.cache = new Map();
    this.pending = new Map();
    this.generations = new Map();
    this.clearGeneration = 0;
  }
  async get({vmAddress, vmID, vmName, forceRefresh = false}) {
    const address = new URL(vmAddress);
    const validVMID = value => typeof value === 'string' && value.length > 0 && value.trim() === value && value.length <= 255;
    const vmIds = address.searchParams.getAll('vm_id');
    if ((vmID !== undefined && !validVMID(vmID)) ||
        (vmIds.length > 0 && (vmIds.length !== 1 || !validVMID(vmIds[0]) || (vmID !== undefined && vmIds[0] !== vmID)))) {
      throw new Error('Invalid gateway address');
    }
    if (vmID !== undefined && vmIds.length === 0) address.searchParams.set('vm_id', vmID);
    const queryKeys = [...new Set(address.searchParams.keys())];
    if (!['https:', 'wss:'].includes(address.protocol) || address.username || address.password || address.hash ||
        (queryKeys.length > 0 && (queryKeys.length !== 1 || queryKeys[0] !== 'vm_id' || address.searchParams.getAll('vm_id').length !== 1))) {
      throw new Error('Invalid gateway address');
    }
    const cacheKey = JSON.stringify([address.href, vmName || null]);
    if (forceRefresh) { this.cache.delete(cacheKey); this.generations.set(cacheKey, (this.generations.get(cacheKey) || 0) + 1); }
    const generation = this.generations.get(cacheKey) || 0;
    const clearGeneration = this.clearGeneration;
    const cached = this.cache.get(cacheKey);
    const expiry = cached && notaryExpirationMs(cached.notaryToken);
    if (!forceRefresh && cached && (expiry === null || this.now() + 60000 < expiry)) return cached;
    if (!forceRefresh && this.pending.has(cacheKey)) return this.pending.get(cacheKey);
    const request = (async () => {
      const response = await this.fetchAuthenticated(MUSE_TOKEN_ENDPOINT, {
        method: 'POST', credentials: 'include', cache: 'no-store',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({vmAddress: address.href, ...(vmName ? {vmName} : {}), ...(forceRefresh ? {force_refresh: true} : {})})
      });
      if (!response.ok) throw new Error(`Admission request failed (${response.status})`);
      const data = await response.json();
      if (typeof data.token !== 'string' || !data.token.trim()) throw new Error('Admission response missing token');
      let notaryToken = typeof data.notary_token === 'string' ? data.notary_token.trim() : null;
      if (notaryToken?.startsWith('delegation.')) {
        if (typeof this.endorseDelegation !== 'function') throw new Error('Notary delegation requires an endorser');
        notaryToken = await this.endorseDelegation({delegation: notaryToken, gatewayUrl: address.href, vmName: vmName || null, path: '/v1/noise'});
        if (typeof notaryToken !== 'string' || !notaryToken.trim()) throw new Error('Invalid notary endorsement');
      }
      const value = {token: data.token, notaryToken, gatewayUrl: address.href, vmName: vmName || null};
      if ((this.generations.get(cacheKey) || 0) !== generation || this.clearGeneration !== clearGeneration) throw new Error('Admission request invalidated');
      this.cache.set(cacheKey, value);
      return value;
    })();
    this.pending.set(cacheKey, request);
    try { return await request; } finally { if (this.pending.get(cacheKey) === request) this.pending.delete(cacheKey); }
  }
  clear() { this.clearGeneration++; this.cache.clear(); this.pending.clear(); }
}
