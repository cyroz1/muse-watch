// Generates deterministic cross-implementation test vectors for the Swift port.
// Uses only fixed, invented keys derived from documented seed strings.
// Output: Checks/Fixtures/vectors.json. Never contains real credentials.
import {createHash, createHmac, createCipheriv, createDecipheriv, createPublicKey, createPrivateKey, diffieHellman, randomBytes} from 'node:crypto';
import {NoiseXXInitiator} from '../muse_noise.mjs';
import {encodeRequest, Decoder} from '../muse_gateway.mjs';
import {writeFileSync, mkdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const EMPTY = Buffer.alloc(0);
const prefix = Buffer.from('302a300506032b656e032100', 'hex');
const pkcs8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const hash = x => createHash('sha256').update(x).digest();
const mac = (k, x) => createHmac('sha256', k).update(x).digest();
const cat = (...x) => Buffer.concat(x);

// Same primitives as muse_noise.mjs; validated against it below via a random-key exchange.
function hkdf(ck, input) { const tmp = mac(ck, input), a = mac(tmp, Buffer.from([1])); return [a, mac(tmp, cat(a, Buffer.from([2])))]; }
class Cipher {
  constructor(key = null) { this.key = key; this.n = 0n; this.failed = false; }
  iv() { if (this.failed || this.n >= (1n << 64n) - 1n) throw Error('Noise cipher unavailable'); const b = Buffer.alloc(12); b.writeBigUInt64BE(this.n++, 4); return b; }
  encrypt(ad, plain) { if (!this.key) return plain; try { const c = createCipheriv('aes-256-gcm', this.key, this.iv()); c.setAAD(ad); return cat(c.update(plain), c.final(), c.getAuthTag()); } catch (e) { this.failed = true; throw e; } }
  decrypt(ad, data) { if (!this.key) return data; try { if (data.length < 16) throw Error('short ciphertext'); const c = createDecipheriv('aes-256-gcm', this.key, this.iv()); c.setAAD(ad); c.setAuthTag(data.subarray(-16)); return cat(c.update(data.subarray(0, -16)), c.final()); } catch (e) { this.failed = true; throw e; } }
}
class Symmetric {
  constructor() { this.h = Buffer.alloc(32); Buffer.from('Noise_XX_25519_AESGCM_SHA256').copy(this.h); this.ck = Buffer.from(this.h); this.c = new Cipher(); this.mixHash(EMPTY); }
  mixHash(x) { this.h = hash(cat(this.h, x)); }
  mixKey(x) { let [ck, k] = hkdf(this.ck, x); this.ck = ck; this.c = new Cipher(k); }
  enc(x) { const r = this.c.encrypt(this.h, x); this.mixHash(r); return r; }
  dec(x) { const r = this.c.decrypt(this.h, x); this.mixHash(x); return r; }
  split() { const [a, b] = hkdf(this.ck, EMPTY); return [new Cipher(a), new Cipher(b)]; }
}
function fixedKey(seed) {
  const privRaw = hash(Buffer.concat([Buffer.from('muse-watch cross-implementation vector: '), Buffer.from(seed)]));
  const priv = createPrivateKey({key: cat(pkcs8, privRaw), format: 'der', type: 'pkcs8'});
  const pub = createPublicKey(priv).export({format: 'der', type: 'spki'}).subarray(-32);
  return {privRaw, priv, pub};
}
// muse_noise keypair contract: raw is the PUBLIC key; privateKey is a KeyObject.
function fixtureKeypair(kp) {
  return {
    privateKey: kp.priv,
    raw: kp.pub,
    publicKey: createPublicKey({key: cat(prefix, kp.pub), format: 'der', type: 'spki'})
  };
}
function dh(priv, rawPub) { return diffieHellman({privateKey: priv, publicKey: createPublicKey({key: cat(prefix, rawPub), format: 'der', type: 'spki'})}); }

// XX responder mirroring the noise-spec complement of muse_noise.mjs.
class XXResponder {
  constructor(serverStatic, serverEphemeral) { this.sSrv = serverStatic; this.eSrv = serverEphemeral; this.s = new Symmetric(); }
  readMessage1(m) {
    if (m.length < 32) throw Error('short message 1');
    this.re = m.subarray(0, 32);
    this.s.mixHash(this.re);
    this.s.dec(m.subarray(32)); // initiator hello payload
  }
  writeMessage2() {
    const out = [this.eSrv.pub];
    this.s.mixHash(this.eSrv.pub);
    this.s.mixKey(dh(this.eSrv.priv, this.re));
    out.push(this.s.enc(this.sSrv.pub));
    this.s.mixKey(dh(this.sSrv.priv, this.re));
    out.push(this.s.enc(EMPTY));
    return cat(...out);
  }
  readMessage3(m) {
    if (m.length < 48) throw Error('short message 3');
    const rs = this.s.dec(m.subarray(0, 48));
    this.s.mixKey(dh(this.eSrv.priv, rs));
    const payload = this.s.dec(m.subarray(48));
    const [a, b] = this.s.split();
    return {payload, clientSendKey: a.key, serverSendKey: b.key, a, b};
  }
}

const hx = b => Buffer.from(b).toString('hex');
const assertEq = (x, y, label) => { if (!x.equals(y)) throw Error(`mismatch: ${label}`); };

// 1. Validate this script's responder against the verified muse_noise initiator with random keys.
{
  const initiator = new NoiseXXInitiator();
  const seed = randomBytes(8).toString('hex');
  const responder = new XXResponder(fixedKey('check-static-' + seed), fixedKey('check-ephe-' + seed));
  const m1 = initiator.message1(cat(Buffer.from([0x0a, 0x20]), randomBytes(32)));
  responder.readMessage1(m1);
  const m2 = responder.writeMessage2();
  const hello = initiator.message2(m2);
  assertEq(hello.serverStaticPublicKey, responder.sSrv.pub, 'random static key');
  assertEq(hello.handshakeHash, Buffer.from(responder.s.h), 'random handshake hash');
  const secret = Buffer.from('cross-check payload', 'utf8');
  const m3 = (await initiator.message3(() => true, secret)).message;
  assertEq(responder.readMessage3(m3).payload, secret, 'random message-3 payload');
}

// 2. Fixed-key deterministic vectors.
const cE = fixedKey('client-ephemeral'), cS = fixedKey('client-static'), sE = fixedKey('server-ephemeral'), sS = fixedKey('server-static');
let keyCalls = 0;
const initiator = new NoiseXXInitiator(() => keyCalls++ === 0 ? fixtureKeypair(cE) : fixtureKeypair(cS));
const responder = new XXResponder(sS, sE);
const nonce32 = hash(Buffer.from('muse-watch vector hello nonce'));
const hello = cat(Buffer.from([0x0a, 0x20]), nonce32);
const message1 = initiator.message1(hello);
const message1Hash = Buffer.from(initiator.message1Hash);
responder.readMessage1(message1);
const message2 = responder.writeMessage2();
const helloBack = initiator.message2(message2);
assertEq(helloBack.serverStaticPublicKey, sS.pub, 'fixed static key');
if (keyCalls !== 1) throw Error('key factory call count');
const message3 = (await initiator.message3(() => true, EMPTY)).message;
const back = responder.readMessage3(message3);
assertEq(back.payload, EMPTY, 'fixed message-3 payload');
// Transport keys: initiator and responder must agree on the split.
const [iSend, iReceive] = initiator.s.split();
assertEq(iSend.key, back.clientSendKey, 'client send key');
assertEq(iReceive.key, back.serverSendKey, 'client receive key');
// Fresh Cipher instances carrying the same keys so counters start at zero like the initiator's transport.
const clientSend = new Cipher(Buffer.from(back.clientSendKey));
const serverSend = new Cipher(Buffer.from(back.serverSendKey));

// 3. Gateway request vector: fixed stream ID and chunk ID (encodeRequest emits deterministic bytes).
const streamId = 1;
const chunkId = 1239786938754329481n; // fits int64
const requestId = '0d252199-a647-4b1c-8f30-3a4a2ac56f92';
const path = '/chat/history?limit=20';
const body = Buffer.from('{"limit":20}', 'utf8');
const headers = [['x-request-id', requestId], ['x-app-id', 'hatch-web'], ['Accept-Language', 'en-US'], ['Content-Type', 'application/json']];
const plainChunks = encodeRequest(streamId, 'GET', path, body, headers, chunkId);
const requestWire = plainChunks.map(c => clientSend.encrypt(EMPTY, c));

// 4. Response direction: server encrypts ServiceFrames; Swift must decode them identically.
const varint = v => { let x = BigInt(v), o = []; do { let b = Number(x & 127n); x >>= 7n; o.push(b | (x ? 128 : 0)); } while (x); return Buffer.from(o); };
const nf = (n, v) => cat(varint(n * 8), varint(v));
const bf = (n, b) => cat(varint(n * 8 + 2), varint(b.length), b);
const header = hf => bf(2, cat(bf(1, Buffer.from('x-request-id')), bf(2, Buffer.from(requestId))));
const frameA = cat(nf(1, streamId), bf(3, cat(nf(1, 200), header()))); // response: status + headers, no body marker
const frameB = cat(nf(1, streamId), bf(4, cat(bf(1, Buffer.from('{"ok":')), nf(2, 0))));
const frameC = cat(nf(1, streamId), bf(4, cat(bf(1, Buffer.from('true, "chat_events": []}')), nf(2, 1))));
const serviceFrames = [frameA, frameB, frameC];
const responseWire = serviceFrames.map(f => {
  const resp = bf(1, f); // ServiceResponse payload
  const chunks = [];
  const count = Math.max(1, Math.ceil(resp.length / 65489));
  for (let i = 0; i < count; i++) chunks.push(cat(nf(1, 55), nf(2, i), nf(3, count), bf(4, resp.subarray(i * 65489, (i + 1) * 65489))));
  return chunks;
}).flat().map(c => serverSend.encrypt(EMPTY, c));

// 5. Self-validate: decode the response wire through the existing JS Decoder.
{
  const dc = new Decoder();
  const seen = responseWire.map(w => dc.feed(Buffer.from(back.b.decrypt(EMPTY, w))));
  if (seen[0]?.kind !== 'response' || seen[0]?.streamId !== streamId || seen[0]?.status !== 200) throw Error('self-check response frame');
  if (seen[1]?.kind !== 'body' || Buffer.from(seen[1].body).toString('utf8') !== '{"ok":') throw Error('self-check body 1');
  if (seen[2]?.kind !== 'body' || seen[2]?.end !== true || Buffer.from(seen[2].body).toString('utf8') !== 'true, "chat_events": []}') throw Error('self-check body 2');
  if (!back.a.decrypt(EMPTY, requestWire[0]).equals(plainChunks[0])) throw Error('self-check request echo');
}

const vectors = {
  comment: 'Deterministic cross-implementation vectors; fixed invented keys only.',
  protocolName: 'Noise_XX_25519_AESGCM_SHA256',
  keys: {
    clientEphemeralPrivate: hx(cE.privRaw), clientEphemeralPublic: hx(cE.pub),
    clientStaticPrivate: hx(cS.privRaw), clientStaticPublic: hx(cS.pub),
    serverEphemeralPrivate: hx(sE.privRaw), serverEphemeralPublic: hx(sE.pub),
    serverStaticPrivate: hx(sS.privRaw), serverStaticPublic: hx(sS.pub)
  },
  hello: hx(hello), nonce: hx(nonce32),
  message1: hx(message1), message1Hash: hx(message1Hash),
  message2: hx(message2), message3: hx(message3),
  transport: {clientSendKey: hx(back.clientSendKey), clientReceiveKey: hx(back.serverSendKey)},
  request: {streamId, chunkId: chunkId.toString(), verb: 'GET', path, headers, requestBody: body.toString('utf8'), plaintextChunks: plainChunks.map(hx), wireFrames: requestWire.map(hx)},
  response: {streamId, serviceFrames: serviceFrames.map(hx), wireFrames: responseWire.map(hx)}
};
mkdirSync(join(root, 'Checks/Fixtures'), {recursive: true});
writeFileSync(join(root, 'Checks/Fixtures/vectors.json'), JSON.stringify(vectors, null, 2));
console.log('vectors.json written; self-checks passed; message1Hash', message1Hash.toString('hex').slice(0, 12));
