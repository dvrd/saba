#!/usr/bin/env python3
"""Independent aioquic1.3.0 authenticated handshake-space wire qualification.

Only fixture protocol instances/transport output vary. Published TLS, AEAD,
header protection, packet parsing, loss timers and close observation stay intact.
"""
import argparse
import asyncio
import json
import aioquic
from aioquic.asyncio import connect, serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.buffer import Buffer, encode_uint_var as var
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated
from aioquic.quic.packet import pull_quic_header, QuicPacketType, encode_long_header_first_byte
from aioquic.tls import Epoch

CASES = {
    'empty': (b'', 10),
    'nonminimal': (b'\x40\x01', 7),
    'appclose': (b'\x1d\x00\x00', 10),
    'ack-unsent': (b'\x02'+var(1<<30)+b'\x00\x00\x00', 10),
    'ack-malformed': (b'\x02\x00', 7),
    'crypto-truncated': (b'\x06\x00\x05x', 7),
    'crypto-overflow': (b'\x06'+var((1<<62)-1)+b'\x01x', 7),
    'crypto-resource': (b'\x06'+var(70000)+b'\x01x', 13),
    'close-truncated': (b'\x1c\x00\x00\x03x', 7),
    'close-valid': (b'\x06\x00\x01\xff\x1c\x00\x00\x00\x06', None),
}
CONTROLS = ('padding-only', 'ack-only')
POSITIVES = ('bad-tag', 'invalid-initial', 'sparse-crypto') + CONTROLS
PEERS = []

def packets(data):
    out=[];at=0
    while at<len(data):
        # Published aioquic pads client UDP datagrams outside the Initial packet.
        if not any(data[at:]):break
        h=pull_quic_header(Buffer(data=data[at:]),host_cid_length=8)
        assert h.packet_length>0 and at+h.packet_length<=len(data)
        out.append((h,data[at:at+h.packet_length]));at+=h.packet_length
    return out

def protected(quic, epoch, payload, pn, wrong_source=False):
    kind=QuicPacketType.INITIAL if epoch==Epoch.INITIAL else QuicPacketType.HANDSHAKE
    destination=quic._peer_cid.cid;source=b'badcid!!' if wrong_source else quic.host_cid
    first=encode_long_header_first_byte(1,kind,3)
    header=bytes([first])+b'\x00\x00\x00\x01'+bytes([len(destination)])+destination+bytes([len(source)])+source
    if epoch==Epoch.INITIAL:header+=b'\x00'
    header+=var(4+len(payload)+16)+pn.to_bytes(4,'big')
    wire=quic._cryptos[epoch].send.encrypt_packet(header,payload,pn)
    assert len(wire)==len(header)+len(payload)+16
    return wire

class FaultTransport:
    def __init__(self, original, peer):self.original,self.peer=original,peer
    def __getattr__(self,name):return getattr(self.original,name)
    def sendto(self,data,address):
        p=self.peer;q=p._quic
        if p.fault is None:return self.original.sendto(data,address)
        if p.injected:
            if p.held and not p.released:
                assert len(p.held)<8,'bounded held flight'
                p.held.append((data,address));return
            if p.positive:return self.original.sendto(data,address)
            return
        initial_fault=(p.fault=='invalid-initial' or (p.fault=='ack-only' and not q.configuration.is_client) or (p.fault=='sparse-crypto' and q.configuration.is_client)) and q._cryptos[Epoch.INITIAL].send.is_valid()
        if not initial_fault and not q._cryptos[Epoch.HANDSHAKE].send.is_valid():return self.original.sendto(data,address)
        items=packets(data)
        # Both keys and the sender's genuine Initial/Handshake flight now exist.
        if not any(h.packet_type in (QuicPacketType.INITIAL,QuicPacketType.HANDSHAKE) for h,_ in items):
            return self.original.sendto(data,address)
        pn=q._packet_number;q._packet_number+=1
        if p.fault=='sparse-crypto':
            epoch=Epoch.INITIAL if q.configuration.is_client else Epoch.HANDSHAKE
            sender=q._crypto_streams[epoch].sender
            genuine=bytes(sender._buffer)
            assert sender._buffer_start==0 and len(genuine)>=66,(epoch,sender._buffer_start,len(genuine))
            # Genuine TLS bytes, deliberately separated before the real flight
            # fills their gaps. Thirty-three bytes used to exhaust32 span slots.
            payload=b''.join(b'\x06'+var(offset)+b'\x01'+genuine[offset:offset+1]
                             for offset in range(1,66,2))
            bad=protected(q,epoch,payload,pn)
            combined=bad+data
            p.control_epoch=epoch;p.sparse_pn=pn
        elif p.fault in CONTROLS:
            epoch=Epoch.INITIAL if p.fault=='ack-only' and not q.configuration.is_client else Epoch.HANDSHAKE
            payload=b'\x02\x00\x00\x00\x00' if p.fault=='ack-only' else b'\x00'*4
            bad=protected(q,epoch,payload,pn)
            combined=bad
            if not q.configuration.is_client and epoch==Epoch.HANDSHAKE:
                combined+=b''.join(raw for h,raw in items if h.packet_type==QuicPacketType.INITIAL)
            p.held.append((data,address));p.control_epoch=epoch
        elif p.fault=='invalid-initial':
            bad=protected(q,Epoch.INITIAL,b'\x40\x01',pn,wrong_source=True)
            combined=bad+data
        else:
            payload=CASES[p.fault][0] if p.fault!='bad-tag' else b'\x01'
            bad=protected(q,Epoch.HANDSHAKE,payload,pn)
            if p.fault=='bad-tag':
                bad=bad[:-1]+bytes([bad[-1]^1]);combined=bad+data
            elif q.configuration.is_client:
                combined=bad
            else:
                # Put HS before Initial: the native client must buffer it, learn
                # keys from genuine ServerHello, then reject before Finished.
                initial=b''.join(raw for h,raw in items if h.packet_type==QuicPacketType.INITIAL)
                assert initial,'server fault requires genuine Initial'
                combined=bad+initial
        assert len(combined)<=4096
        p.injected=True;p.injection=dict(packet_number=pn,bytes=len(combined),payload_bytes=len(payload) if p.fault!='invalid-initial' else 2,
            types=[h.packet_type.name for h,_ in packets(combined)])
        self.original.sendto(combined,address)

class Peer(QuicConnectionProtocol):
    def __init__(self,*args,fault=None,**kwargs):
        super().__init__(*args,**kwargs);PEERS.append(self)
        self.fault=fault;self.positive=fault in POSITIVES
        self.injected=False;self.injection={};self.calls=0
        self.held=[];self.released=False;self.observed_acks=0;self.control_epoch=None;self.release_reason=None
        self.sparse_pn=None;self.sparse_acked=False
        self.http=H3Connection(self._quic);self.events=asyncio.Queue()
        self.terminal=asyncio.get_running_loop().create_future()
    def connection_made(self,transport):super().connection_made(FaultTransport(transport,self))
    def _handle_timer(self):
        if self.held and not self.released:
            assert self._quic._loss_at is not None, 'release requires published loss timer'
            assert self._timer_at >= self._quic._loss_at
            self.released=True;self.release_reason='published loss timer'
            for data,address in self.held:self._transport.original.sendto(data,address)
            self.held.clear()
        super()._handle_timer()
    def datagram_received(self,data,address):
        if self.injected and self.control_epoch is not None and not self.released:
            kind=QuicPacketType.INITIAL if self.control_epoch==Epoch.INITIAL else QuicPacketType.HANDSHAKE
            for h,raw in packets(data):
                if h.packet_type!=kind:continue
                if not self._quic._cryptos[self.control_epoch].recv.is_valid():continue
                buf=Buffer(data=raw);pull_quic_header(buf,host_cid_length=8)
                # Long-header AEAD/header protection is stateless: this passive
                # observation leaves the published peer parser untouched.
                _,plain,_,_=self._quic._cryptos[self.control_epoch].recv.decrypt_packet(raw,buf.tell(),0)
                frame=Buffer(data=plain)
                while not frame.eof():
                    t=frame.pull_uint_var()
                    if t in (0,1):continue
                    if t in (2,3):
                        self.observed_acks+=1
                        upper=frame.pull_uint_var();frame.pull_uint_var();n=frame.pull_uint_var()
                        lower=upper-frame.pull_uint_var()
                        if self.sparse_pn is not None and lower<=self.sparse_pn<=upper:self.sparse_acked=True
                        for _ in range(n):
                            upper=lower-frame.pull_uint_var()-2;lower=upper-frame.pull_uint_var()
                            if self.sparse_pn is not None and lower<=self.sparse_pn<=upper:self.sparse_acked=True
                        if t==3:
                            for _ in range(3):frame.pull_uint_var()
                    elif t==6:
                        frame.pull_uint_var();frame.pull_bytes(frame.pull_uint_var())
                    elif t==28:
                        frame.pull_uint_var();frame.pull_uint_var();frame.pull_bytes(frame.pull_uint_var())
                    else:raise AssertionError(('unexpected handshake frame',t))
        super().datagram_received(data,address)
    def control_result(self):
        if self.fault not in CONTROLS:return {}
        assert self.released and self.observed_acks==0,(self.release_reason,self.observed_acks)
        return dict(release=self.release_reason,observed_ack_frames=self.observed_acks,epoch=self.control_epoch.name)
    def fragmentation_result(self):
        if self.fault!='sparse-crypto':return {}
        # Normal HTTP alone would hide a silently discarded Initial injection.
        # Require an independently decrypted ACK covering that exact packet.
        assert self.sparse_acked,(self.sparse_pn,self.observed_acks,self.control_epoch)
        return dict(bytes=33,fragments=33,first_offset=1,last_offset=65,
                    epoch=self.control_epoch.name,packet_number=self.sparse_pn,acknowledged=True)
    def quic_event_received(self,event):
        if isinstance(event,ConnectionTerminated) and not self.terminal.done():self.terminal.set_result(event)
        for e in self.http.handle_event(event):
            if not self._quic.configuration.is_client and isinstance(e,HeadersReceived):
                self.calls+=1
                assert dict(e.headers)[b':path']==b'/probe'
                self.http.send_headers(e.stream_id,[(b':status',b'200')]);self.http.send_data(e.stream_id,b'wire-ok',end_stream=True);self.transmit()
            else:self.events.put_nowait(e)
    async def get(self):
        stream=self._quic.get_next_available_stream_id()
        self.http.send_headers(stream,[(b':method',b'GET'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/probe')],end_stream=True);self.transmit()
        body=b'';status=None
        while True:
            e=await asyncio.wait_for(self.events.get(),8)
            if isinstance(e,HeadersReceived):status=dict(e.headers)[b':status']
            if isinstance(e,DataReceived):
                body+=e.data
                if e.stream_ended:break
        assert status==b'200' and body==b'wire-ok',(status,body)

async def native(args,mode,port):
    p=await asyncio.create_subprocess_exec(args.binary,mode,str(port),args.cert,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:out,err=await asyncio.wait_for(p.communicate(),12)
    except BaseException:
        if p.returncode is None:p.kill()
        await p.wait();raise
    record=dict(returncode=p.returncode,stdout=out.decode(),stderr=err.decode())
    assert p.returncode==0 and b'AddressSanitizer' not in err and b'ThreadSanitizer' not in err,record
    return record

async def run(args):
    assert aioquic.__version__=='1.3.0'
    direction,case=args.mode.split('-',1);positive=case in POSITIVES
    report=dict(case=args.mode,peer='aioquic '+aioquic.__version__)
    if direction=='server':
        config=QuicConfiguration(is_client=False,alpn_protocols=['h3'],max_datagram_size=1200,idle_timeout=1 if case=='close-valid' else 60);config.load_cert_chain(args.cert,args.key)
        server=await serve('127.0.0.1',0,configuration=config,create_protocol=lambda *a,**kw:Peer(*a,fault=case,**kw))
        try:
            port=server._transport.get_extra_info('sockname')[1]
            report['native']=await native(args,'client' if positive else 'client-error',port)
            peer=PEERS[-1];assert peer.injected
            if not positive:
                terminal=await asyncio.wait_for(peer.terminal,8)
                assert terminal.error_code==(1 if case=='close-valid' else CASES[case][1]),terminal
                if case=='close-valid':assert terminal.reason_phrase=='Idle timeout',terminal
                report['close_code']=terminal.error_code;report['terminal_reason']=terminal.reason_phrase
            assert peer.calls==(1 if positive else 0),peer.calls
            report.update(injection=peer.injection,calls=peer.calls,noneliciting=peer.control_result(),
                          crypto_fragmentation=peer.fragmentation_result())
        finally:server.close()
    else:
        process=await asyncio.create_subprocess_exec(args.binary,'server',args.cert,args.key,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        try:
            line=await asyncio.wait_for(process.stdout.readline(),8);assert line.startswith(b'READY '),line;port=int(line.split()[1])
            config=QuicConfiguration(is_client=True,alpn_protocols=['h3'],max_datagram_size=1200,idle_timeout=1 if case=='close-valid' else 60);config.load_verify_locations(args.cert);config.server_name='localhost'
            async with connect('127.0.0.1',port,configuration=config,create_protocol=lambda *a,**kw:Peer(*a,fault=case,**kw),wait_connected=False) as peer:
                peer.transmit()
                if positive:
                    await asyncio.wait_for(peer.wait_connected(),8);await peer.get()
                else:
                    terminal=await asyncio.wait_for(peer.terminal,8)
                    assert terminal.error_code==(1 if case=='close-valid' else CASES[case][1]),terminal
                    if case=='close-valid':assert terminal.reason_phrase=='Idle timeout',terminal
                    report['close_code']=terminal.error_code;report['terminal_reason']=terminal.reason_phrase
                assert peer.injected;report['injection']=peer.injection;report['noneliciting']=peer.control_result()
                report['crypto_fragmentation']=peer.fragmentation_result()
            # The same one-slot normal Saba listener must accept fresh work.
            async with connect('127.0.0.1',port,configuration=config,create_protocol=Peer) as fresh:await fresh.get()
            process.stdin.write(b's');await process.stdin.drain();out,err=await asyncio.wait_for(process.communicate(),8)
            expected=2 if positive else 1
            assert process.returncode==0 and f'RESULT calls={expected}' in out.decode(),(out,err)
            assert b'AddressSanitizer' not in err and b'ThreadSanitizer' not in err,(out,err)
            report['server']=dict(stdout=out.decode(),stderr=err.decode(),calls=expected)
        finally:
            if process.returncode is None:process.kill();await process.wait()
    print(json.dumps(report))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode');p.add_argument('--binary',required=True);p.add_argument('--cert',required=True);p.add_argument('--key',required=True);asyncio.run(run(p.parse_args()))
