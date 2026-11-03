"""Muse gateway protobuf framing. No network, encryption or authentication."""
from pathlib import Path
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
import secrets

DESCRIPTORS = Path(__file__).resolve().with_name('muse-noise-descriptors.pb')
_pool = descriptor_pool.DescriptorPool()
_set = descriptor_pb2.FileDescriptorSet.FromString(DESCRIPTORS.read_bytes())
for descriptor in _set.file:
    _pool.Add(descriptor)

def cls(name):
    return message_factory.GetMessageClass(_pool.FindMessageTypeByName(name))

Frame = cls('hatch.noise.ServiceFrame')
Request = cls('hatch.noise.ServiceRequest')
Response = cls('hatch.noise.ServiceResponse')
Chunk = cls('ingress_rev_proxy.NoiseTransportFrame')
MAX_CHUNK = 65489

def encode_request(stream_id, verb, path, body=b'', headers=(), service=0, chunk_id=None):
    if stream_id < 1 or not path.startswith('/'):
        raise ValueError('invalid stream or path')
    app = Frame(stream_id=stream_id)
    app.request.verb, app.request.path, app.request.body, app.request.end_body = verb, path, body, True
    for key, value in headers:
        app.request.headers.add(key=key, value=value)
    raw = Request(service=service, payload=app.SerializeToString()).SerializeToString()
    count = max(1, (len(raw) + MAX_CHUNK - 1) // MAX_CHUNK)
    if count > 256: raise ValueError('request too large')
    if chunk_id is None: chunk_id = int.from_bytes(secrets.token_bytes(8), 'little', signed=True)
    return [Chunk(chunk_id=chunk_id, chunk_index=i, total_chunks=count, payload=raw[i*MAX_CHUNK:(i+1)*MAX_CHUNK]).SerializeToString() for i in range(count)]

class ResponseAssembler:
    def __init__(self): self.pending = {}
    def feed(self, plaintext):
        c = Chunk.FromString(plaintext)
        if not (1 <= c.total_chunks <= 256 and c.chunk_index < c.total_chunks and len(c.payload) <= MAX_CHUNK):
            raise ValueError('invalid chunk')
        if c.chunk_id not in self.pending:
            if len(self.pending) >= 16: raise ValueError('too many incomplete messages')
            self.pending[c.chunk_id] = (c.total_chunks, {})
        total, parts = self.pending[c.chunk_id]
        if total != c.total_chunks or c.chunk_index in parts:
            del self.pending[c.chunk_id]
            raise ValueError('inconsistent or duplicate chunk')
        parts[c.chunk_index] = c.payload
        if sum(map(len, parts.values())) > 0x1000000:
            del self.pending[c.chunk_id]; raise ValueError('assembly too large')
        if len(parts) != total: return None
        del self.pending[c.chunk_id]
        response = Response.FromString(b''.join(parts[i] for i in range(total)))
        if not response.payload: raise ValueError('empty service response')
        return Frame.FromString(response.payload)
