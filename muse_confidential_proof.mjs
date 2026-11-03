// Research implementation of the owner RV proof. Caller must independently verify
// attestation, chip authorization and expected VM identity BEFORE invoking it.
import {createHmac,timingSafeEqual} from 'node:crypto';
const B=x=>Buffer.isBuffer(x)?x:Buffer.from(x), join=(...x)=>Buffer.concat(x), str=x=>Buffer.from(x,'utf8');
const mac=(k,m)=>createHmac('sha256',k).update(m).digest();
const key=(rv,label)=>mac(rv,join(str('hatch.noise-auth.key.v1'),str(label)));
const size=(x,n,name)=>{x=B(x);if(x.length!==n)throw Error(`${name} must be ${n} bytes`);return x};
function v(n){let o=[];do{let b=n&127;n>>>=7;o.push(b|(n?128:0))}while(n);return Buffer.from(o)}
function field(n,b){b=B(b);return join(v(n*8+2),v(b.length),b)}
export function buildProvisionedProof({rvKey,notaryToken,message1Hash,message2Hash,clientNonce,vmNonce,vmProof,attestationVerified}){
 if(attestationVerified!==true)throw Error('Verified VM attestation is required');
 rvKey=size(rvKey,32,'RV key');message1Hash=size(message1Hash,32,'message 1 hash');message2Hash=size(message2Hash,32,'message 2 hash');clientNonce=size(clientNonce,32,'client nonce');vmNonce=size(vmNonce,32,'VM nonce');vmProof=size(vmProof,32,'VM proof');
 if(typeof notaryToken!=='string'||!notaryToken.trim())throw Error('notary token required');
 const vmKey=key(rvKey,'vm-proof-key');const expected=mac(vmKey,join(str('hatch.noise-auth.vm-proof.v1'),message1Hash,clientNonce,vmNonce));vmKey.fill(0);
 if(!timingSafeEqual(expected,vmProof)){expected.fill(0);throw Error('VM proof mismatch')};expected.fill(0);
 const clientKey=key(rvKey,'client-proof-key'),proof=mac(clientKey,join(str('hatch.noise-auth.client-proof.v1'),message2Hash,vmNonce,clientNonce));clientKey.fill(0);
 try{return join(field(1,str(notaryToken.trim())),field(3,proof))}finally{proof.fill(0)}
}
