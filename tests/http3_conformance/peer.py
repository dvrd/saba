#!/usr/bin/env python3
"""Independent aioquic 1.3.0 wire conformance; only fixture policy/UDP faults vary."""
import argparse, asyncio, json, ssl
import aioquic
from aioquic.asyncio import connect, serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.buffer import Buffer, encode_uint_var
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated
from aioquic.quic.packet import pull_quic_header, encode_quic_version_negotiation, QuicPacketType

STATE = {"calls": 0, "close_codes": []}
INVALID = False
FAULT = ''
ZERO = False
PEERS = []

class Peer(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        PEERS.append(self)
        # Fault only the fixture's serialized local TP; published parser/crypto remain intact.
        if INVALID:
            if FAULT == 'limit':
                # Append a well-formed unknown 1200-byte TP at this fixture instance only.
                # This exercises the native bounded aggregate, not malformed QUIC/TLS.
                serialize = self._quic._serialize_transport_parameters
                self._quic._serialize_transport_parameters = lambda: serialize() + encode_uint_var(0x1234) + encode_uint_var(1200) + b'\0'*1200
            else:
                self._quic._local_ack_delay_exponent = 21
        if ZERO:
            # Configure a legal zero-CID server policy at the fixture instance.
            # aioquic defaults otherwise emit forbidden spare IDs/reset TP for CID0.
            assert not self._quic.configuration.is_client and not self._quic.host_cid
            self._quic._replenish_connection_ids = lambda: None
            self._quic._host_cids[0].stateless_reset_token = None
        self.http = H3Connection(self._quic)
        self.events = asyncio.Queue()
        self.terminal = asyncio.get_running_loop().create_future()
    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            STATE["close_codes"].append(event.error_code)
            if not self.terminal.done(): self.terminal.set_result(event)
        for e in self.http.handle_event(event):
            if not self._quic.configuration.is_client and isinstance(e, HeadersReceived):
                STATE["calls"] += 1
                assert dict(e.headers)[b':path'] == b'/probe'
                self.http.send_headers(e.stream_id, [(b':status', b'200')])
                self.http.send_data(e.stream_id, b'wire-ok', end_stream=True)
                self.transmit()
            else:
                self.events.put_nowait(e)
    async def get(self):
        stream = self._quic.get_next_available_stream_id()
        self.http.send_headers(stream, [(b':method', b'GET'), (b':scheme', b'https'),
            (b':authority', b'localhost'), (b':path', b'/probe')], end_stream=True)
        self.transmit()
        body = b''; status = None
        while True:
            e = await asyncio.wait_for(self.events.get(), 10)
            if isinstance(e, HeadersReceived): status = dict(e.headers)[b':status']
            if isinstance(e, DataReceived):
                body += e.data
                if e.stream_ended: break
        assert status == b'200' and body == b'wire-ok', (status, body)

def packets(data):
    result = []; offset = 0
    while offset < len(data):
        h = pull_quic_header(Buffer(data=data[offset:]), host_cid_length=8)
        n = h.packet_length
        assert n > 0 and offset+n <= len(data)
        result.append((h, data[offset:offset+n])); offset += n
    return result

class Relay(asyncio.DatagramProtocol):
    def __init__(self, server, mode):
        self.server = server; self.mode = mode; self.client = None
        self.injected = False; self.cached = {}; self.coalesced = False; self.prefixed = False
        self.observed = set(); self.sizes = []; self.coalesced_types = []; self.prefixed_types = []
    def connection_made(self, transport): self.transport = transport
    def datagram_received(self, data, addr):
        if addr != self.server:
            self.client = addr
            if not self.injected:
                h = packets(data)[0][0]
                assert h.packet_type == QuicPacketType.INITIAL and len(data) >= 1200
                self.injected = True
                if self.mode in ('vn-ignore', 'vn-abort'):
                    if self.mode == 'vn-ignore':
                        wrong = bytes([h.source_cid[0]^1])+h.source_cid[1:]
                        self.transport.sendto(encode_quic_version_negotiation(h.destination_cid, wrong, [0x7a7a7a7a]), addr)
                        self.transport.sendto(encode_quic_version_negotiation(h.destination_cid, h.source_cid, [1,0x7a7a7a7a]), addr)
                        asyncio.get_running_loop().call_later(.02, self.transport.sendto, data, self.server)
                    else:
                        self.transport.sendto(encode_quic_version_negotiation(h.destination_cid, h.source_cid, [0x7a7a7a7a]), addr)
                    return
                if self.mode == 'bad-first':
                    bad = bytearray(data); bad[-1] ^= 1
                    combined = bytes(bad)+data
                    assert len(combined) <= 4096
                    # Invariant bytes and CID bindings unchanged; only protected tag differs.
                    assert packets(bytes(bad))[0][0].source_cid == h.source_cid
                    assert packets(bytes(bad))[0][0].destination_cid == h.destination_cid
                    self.sizes.append(len(combined)); self.transport.sendto(combined, self.server); return
            if self.mode != 'vn-abort': self.transport.sendto(data, self.server)
            return
        if self.mode == 'coalesce':
            items = packets(data)
            for h, raw in items:
                self.observed.add(h.packet_type.name)
                if h.packet_type in (QuicPacketType.INITIAL, QuicPacketType.HANDSHAKE):
                    self.cached[h.packet_type] = raw
            if all(t in self.cached for t in (QuicPacketType.INITIAL, QuicPacketType.HANDSHAKE)):
                prefix = self.cached[QuicPacketType.INITIAL]+self.cached[QuicPacketType.HANDSHAKE]
                if any(h.packet_type == QuicPacketType.HANDSHAKE for h, _ in items) and not self.coalesced:
                    assert len(prefix) <= 4096
                    self.coalesced_types = [h.packet_type.name for h,_ in packets(prefix)]
                    assert self.coalesced_types == ['INITIAL', 'HANDSHAKE']
                    self.coalesced = True; self.sizes.append(len(prefix)); self.transport.sendto(prefix, self.client)
                    # Preserve any genuine short packets sharing the original UDP.
                    short = b''.join(raw for h,raw in items if h.packet_type == QuicPacketType.ONE_RTT)
                    if short: self.transport.sendto(short, self.client)
                    return
                if any(h.packet_type == QuicPacketType.ONE_RTT for h, _ in items) and not self.prefixed:
                    pair = prefix
                    while len(prefix+data) < 1200:
                        prefix += pair
                    combined = prefix+data
                    assert 1200 <= len(combined) <= 4096
                    self.prefixed_types = [h.packet_type.name for h,_ in packets(combined)]
                    assert self.prefixed_types[:2] == ['INITIAL', 'HANDSHAKE'] and self.prefixed_types[-1] == 'ONE_RTT'
                    self.prefixed = True; self.sizes.append(len(combined)); self.transport.sendto(combined, self.client); return
        self.transport.sendto(data, self.client)

async def native(args, mode, port):
    p = await asyncio.create_subprocess_exec(args.binary, mode, str(port), args.cert,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try: out, err = await asyncio.wait_for(p.communicate(), 18)
    except BaseException:
        p.kill(); await p.wait(); raise
    record = dict(returncode=p.returncode, stdout=out.decode(), stderr=err.decode())
    assert p.returncode == 0 and b'AddressSanitizer' not in err and b'ThreadSanitizer' not in err, record
    return record

async def native_server(args):
    p = await asyncio.create_subprocess_exec(args.binary, 'server', args.cert, args.key,
        stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        line = await asyncio.wait_for(p.stdout.readline(),10)
        assert line.startswith(b'READY '), line
        return p, int(line.split()[1])
    except BaseException:
        if p.returncode is None: p.kill()
        await p.wait()
        raise

async def stop_server(p, expected_calls):
    p.stdin.write(b's'); await p.stdin.drain()
    out,err = await asyncio.wait_for(p.communicate(),10)
    result = dict(returncode=p.returncode, stdout=out.decode(), stderr=err.decode())
    assert p.returncode==0 and f'RESULT calls={expected_calls}' in result['stdout'],result
    assert b'AddressSanitizer' not in err and b'ThreadSanitizer' not in err,result
    return result

async def main(a):
    global INVALID, FAULT, ZERO
    assert aioquic.__version__ == '1.3.0'
    report = {'case':a.mode,'peer':'aioquic '+aioquic.__version__}
    if a.mode in ('vn-ignore','vn-abort','coalesce','invalid-server','invalid-server-limit','zero-server-cid'):
        ZERO = a.mode == 'zero-server-cid'
        INVALID = a.mode.startswith('invalid-server')
        FAULT = 'limit' if a.mode.endswith('-limit') else ''
        cfg=QuicConfiguration(is_client=False,alpn_protocols=['h3'],max_datagram_size=1200,connection_id_length=0 if ZERO else 8)
        cfg.load_cert_chain(a.cert,a.key)
        server=await serve('127.0.0.1',0,configuration=cfg,create_protocol=Peer)
        port=server._transport.get_extra_info('sockname')[1]
        transport,relay=await asyncio.get_running_loop().create_datagram_endpoint(
            lambda:Relay(('127.0.0.1',port),a.mode),local_addr=('127.0.0.1',0))
        try:
            mode='client-vn' if a.mode=='vn-abort' else 'client-tp' if INVALID else 'client'
            report['native']=await native(a,mode,transport.get_extra_info('sockname')[1])
            assert STATE['calls']==(0 if a.mode in ('vn-abort','invalid-server','invalid-server-limit') else 1),STATE
            if a.mode == 'vn-abort': assert not PEERS, 'unsupported VN must abort before independent TLS admission'
            if INVALID:
                assert PEERS
                terminal = await asyncio.wait_for(PEERS[-1].terminal, 8)
                assert terminal.error_code == (13 if FAULT == 'limit' else 8), terminal
            if a.mode=='coalesce': assert relay.coalesced and relay.prefixed,vars(relay)
            if ZERO:
                assert PEERS and all(not p._quic.host_cid and len(p._quic._host_cids)==1 for p in PEERS)
                report['configured_server_cid_length']=0
            report.update(calls=STATE['calls'],peer_connections=len(PEERS),close_codes=STATE['close_codes'],injected=relay.injected,
                coalesced=relay.coalesced,prefixed=relay.prefixed,packet_types=sorted(relay.observed),udp_sizes=relay.sizes,coalesced_types=relay.coalesced_types,prefixed_types=relay.prefixed_types)
        finally: transport.close();server.close()
    else:
        p,port=await native_server(a)
        try:
            if a.mode=='head-semantics':
                report['native']=await native(a,'client-head',port)
            elif a.mode=='bad-first':
                transport,relay=await asyncio.get_running_loop().create_datagram_endpoint(
                    lambda:Relay(('127.0.0.1',port),a.mode),local_addr=('127.0.0.1',0))
                try: report['native']=await native(a,'client',transport.get_extra_info('sockname')[1])
                finally: transport.close()
                assert relay.injected and relay.sizes,[relay.injected,relay.sizes]
                report['udp_sizes']=relay.sizes
            elif a.mode.startswith('invalid-client'):
                INVALID=True
                FAULT='limit' if a.mode.endswith('-limit') else ''
                cfg=QuicConfiguration(is_client=True,alpn_protocols=['h3']);cfg.load_verify_locations(a.cert);cfg.server_name='localhost'
                async with connect('127.0.0.1',port,configuration=cfg,create_protocol=Peer,wait_connected=False) as peer:
                    peer.transmit()
                    event=await asyncio.wait_for(peer.terminal,10)
                    assert event.error_code==(13 if FAULT=='limit' else 8),event
                    report['close_code']=event.error_code
            elif a.mode=='stateless-vn':
                class Raw(asyncio.DatagramProtocol):
                    def connection_made(self,t):self.t=t;self.q=asyncio.Queue()
                    def datagram_received(self,data,addr):self.q.put_nowait((data,addr))
                transport,raw=await asyncio.get_running_loop().create_datagram_endpoint(Raw,local_addr=('127.0.0.1',0))
                try:
                    report['cid_lengths']=[]
                    for size in (21,255):
                        dcid=bytes(i%251 for i in range(size));scid=bytes((i+71)%251 for i in range(size))
                        packet=b'\xc0'+(0x7a7a7a7a).to_bytes(4,'big')+bytes([size])+dcid+bytes([size])+scid
                        transport.sendto(packet.ljust(1200,b'\0'),('127.0.0.1',port))
                        data,addr=await asyncio.wait_for(raw.q.get(),3)
                        # VN invariant permits IDs beyond supported QUIC packet CID bounds.
                        assert addr==('127.0.0.1',port) and data[1:5]==b'\0'*4
                        n=data[5];dst=data[6:6+n];m=data[6+n];src=data[7+n:7+n+m]
                        versions=data[7+n+m:]
                        assert dst==scid and src==dcid and versions==b'\0\0\0\1',(size,data.hex())
                        assert len(data)==11+2*size
                        report['cid_lengths'].append(size)
                finally:transport.close()
                report['native']=await native(a,'client',port)
            report['server']=await stop_server(p,0 if a.mode.startswith('invalid-client') else 3 if a.mode=='head-semantics' else 1)
        finally:
            if p.returncode is None:p.kill();await p.wait()
    print(json.dumps(report,sort_keys=True),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['vn-ignore','vn-abort','bad-first','coalesce','invalid-server','invalid-client','invalid-server-limit','invalid-client-limit','zero-server-cid','stateless-vn','head-semantics'])
    p.add_argument('--binary',required=True);p.add_argument('--cert',required=True);p.add_argument('--key',required=True)
    asyncio.run(main(p.parse_args()))
