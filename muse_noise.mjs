// Experimental Noise XX initiator. Never connect without verifying the peer.
// Node.js built-in crypto; no network, token acquisition or VM attestation.
import { createHash, createHmac, createCipheriv, createDecipheriv, createPublicKey, generateKeyPairSync, diffieHellman } from 'node:crypto';
const EMPTY = Buffer.alloc(0);
const prefix = Buffer.from('302a300506032b656e032100', 'hex');
const hash = x => createHash('sha256').update(x).digest();
const mac = (k,x) => createHmac('sha256',k).update(x).digest();
const cat = (...x) => Buffer.concat(x);
function hkdf(ck, input) { const tmp=mac(ck,input), a=mac(tmp,Buffer.from([1])); return [a,mac(tmp,cat(a,Buffer.from([2])))]; }
function keypair() {const p=generateKeyPairSync('x25519');return {...p,raw:p.publicKey.export({format:'der',type:'spki'}).subarray(-32)};}
function dh(privateKey, raw) {return diffieHellman({privateKey,publicKey:createPublicKey({key:cat(prefix,raw),format:'der',type:'spki'})});}
class Cipher {
  constructor(key=null){this.key=key;this.n=0n;this.failed=false;}
  iv(){if(this.failed||this.n >= (1n<<64n)-1n) throw Error('Noise cipher unavailable');const b=Buffer.alloc(12);b.writeBigUInt64BE(this.n++,4);return b;}
  encrypt(ad,plain){if(!this.key)return plain;try{const c=createCipheriv('aes-256-gcm',this.key,this.iv());c.setAAD(ad);return cat(c.update(plain),c.final(),c.getAuthTag());}catch(e){this.failed=true;throw e;}}
  decrypt(ad,data){if(!this.key)return data;try{if(data.length<16) throw Error('short ciphertext');const c=createDecipheriv('aes-256-gcm',this.key,this.iv());c.setAAD(ad);c.setAuthTag(data.subarray(-16));return cat(c.update(data.subarray(0,-16)),c.final());}catch(e){this.failed=true;throw e;}}
}
class Symmetric {
  constructor(){this.h=Buffer.alloc(32);Buffer.from('Noise_XX_25519_AESGCM_SHA256').copy(this.h);this.ck=Buffer.from(this.h);this.c=new Cipher();this.mixHash(EMPTY);}
  mixHash(x){this.h=hash(cat(this.h,x));}
  mixKey(x){let [ck,k]=hkdf(this.ck,x);this.ck=ck;this.c=new Cipher(k);}
  enc(x){const r=this.c.encrypt(this.h,x);this.mixHash(r);return r;}
  dec(x){const r=this.c.decrypt(this.h,x);this.mixHash(x);return r;}
  split(){const [a,b]=hkdf(this.ck,EMPTY);return [new Cipher(a),new Cipher(b)];}
}
export class NoiseXXInitiator {
  constructor(){this.s=new Symmetric();this.phase=0;}
  message1(payload=EMPTY){if(this.phase!==0)throw Error('wrong phase');this.e=keypair();this.s.mixHash(this.e.raw);const result=cat(this.e.raw,this.s.enc(Buffer.from(payload)));this.message1Hash=Buffer.from(this.s.h);this.phase=1;return result;}
  message2(message){if(this.phase!==1)throw Error('wrong phase');try{let m=Buffer.from(message);if(m.length<96)throw Error('short handshake');this.re=m.subarray(0,32);this.s.mixHash(this.re);this.s.mixKey(dh(this.e.privateKey,this.re));this.rs=this.s.dec(m.subarray(32,80));this.s.mixKey(dh(this.e.privateKey,this.rs));const payload=this.s.dec(m.subarray(80));this.phase=2;return {payload,serverStaticPublicKey:Buffer.from(this.rs),handshakeHash:Buffer.from(this.s.h)};}catch(e){this.phase=-1;throw e;}}
  async message3(verify, payload=EMPTY){if(this.phase!==2||typeof verify!=='function')throw Error('peer verification required');try{if(await verify({serverStaticPublicKey:Buffer.from(this.rs),handshakeHash:Buffer.from(this.s.h)})!==true)throw Error('peer verification failed');this.localStatic=keypair();let first=this.s.enc(this.localStatic.raw);this.s.mixKey(dh(this.localStatic.privateKey,this.re));let last=this.s.enc(Buffer.from(payload));const [send,receive]=this.s.split();this.phase=3;return {message:cat(first,last),encrypt:data=>send.encrypt(EMPTY,Buffer.from(data)),decrypt:data=>receive.decrypt(EMPTY,Buffer.from(data))};}catch(e){this.phase=-1;throw e;}}
}
