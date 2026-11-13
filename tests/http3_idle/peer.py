#!/usr/bin/env python3
"""Published aioquic 1.3.0 wire checks for negotiated QUIC idle ownership."""
import argparse
import asyncio
import json
import math
import aioquic
from aioquic.asyncio import connect, serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated
from aioquic.tls import Epoch

PEERS=[]
class Peer(QuicConnectionProtocol):
    def __init__(self,*a,**kw):
        super().__init__(*a,**kw);PEERS.append(self)
        self.http=H3Connection(self._quic);self.events=asyncio.Queue();self.calls=0
        self.terminal=asyncio.get_running_loop().create_future()
    def quic_event_received(self,event):
        if isinstance(event,ConnectionTerminated) and not self.terminal.done():
            self.terminal.set_result(event)
        for e in self.http.handle_event(event):
            if not self._quic.configuration.is_client and isinstance(e,HeadersReceived):
                assert dict(e.headers)[b':path']==b'/probe';self.calls+=1
                self.http.send_headers(e.stream_id,[(b':status',b'200')])
                self.http.send_data(e.stream_id,b'idle-ok',end_stream=True);self.transmit()
            else:self.events.put_nowait(e)
    async def get(self):
        stream=self._quic.get_next_available_stream_id()
        self.http.send_headers(stream,[(b':method',b'GET'),(b':scheme',b'https'),
            (b':authority',b'localhost'),(b':path',b'/probe')],end_stream=True)
        self.transmit();body=b'';status=None
        while True:
            e=await asyncio.wait_for(self.events.get(),8)
            if isinstance(e,HeadersReceived):status=dict(e.headers)[b':status']
            if isinstance(e,DataReceived):
                body+=e.data
                if e.stream_ended:break
        assert status==b'200' and body==b'idle-ok',(status,body)

class ActivePeer(Peer):
    def quic_event_received(self,event):
        if isinstance(event,ConnectionTerminated) and not self.terminal.done():
            self.terminal.set_result(event)
        for e in self.http.handle_event(event):
            if isinstance(e,HeadersReceived):
                assert dict(e.headers)[b':path']==b'/probe';self.calls+=1
                if self.calls==1:self.activity=asyncio.create_task(self.active_response(e.stream_id))
                else:self.respond(e.stream_id)
    def respond(self,stream):
        self.http.send_headers(stream,[(b':status',b'200')])
        self.http.send_data(stream,b'idle-ok',end_stream=True);self.transmit()
    async def active_response(self,stream):
        loop=asyncio.get_running_loop();self.activity_start=loop.time()
        timeout=self._quic._idle_timeout();interval=timeout*.2
        for i in range(15):
            await at(self.activity_start+(i+1)*interval)
            await asyncio.wait_for(self.ping(),3)
        self.activity_elapsed=loop.time()-self.activity_start;self.respond(stream)

def config(args,client):
    c=QuicConfiguration(is_client=client,alpn_protocols=['h3'],idle_timeout=.4,
        max_datagram_size=1200)
    if client:c.load_verify_locations(args.cert);c.server_name='localhost'
    else:c.load_cert_chain(args.cert,args.key)
    return c

async def at(deadline):
    """Bounded event scheduled from an observed transport deadline."""
    loop=asyncio.get_running_loop();f=loop.create_future()
    timer=loop.call_at(deadline,lambda:None if f.done() else f.set_result(None))
    try:await asyncio.wait_for(f,max(0,deadline-loop.time())+1)
    finally:timer.cancel()

async def line(process,prefix):
    value=await asyncio.wait_for(process.stdout.readline(),8)
    assert value.startswith(prefix),value
    return value.decode().strip().split()

async def timing(process):
    process.stdin.write(b't');await process.stdin.drain()
    fields=await line(process,b'TIMING ')
    if fields[1]=='none':return None
    remaining,pto,effective,negotiated=map(int,fields[1:5])
    assert effective>=3*pto and effective>=negotiated,(remaining,pto,effective,negotiated)
    assert negotiated==400,(remaining,pto,effective,negotiated)
    return dict(remaining_ms=remaining,base_pto_ms=pto,effective_ms=effective,
        negotiated_ms=negotiated,expired=fields[5])

async def finish(process,calls):
    process.stdin.write(b's');await process.stdin.drain()
    out,err=await asyncio.wait_for(process.communicate(),8)
    assert process.returncode==0 and f'RESULT calls={calls}' in out.decode(),(out,err)
    assert b'AddressSanitizer' not in err and b'ThreadSanitizer' not in err,(out,err)
    return dict(stdout=out.decode(),stderr=err.decode(),calls=calls)

def forged_ping(peer):
    q=peer._quic;pn=q._packet_number;q._packet_number+=1
    keys=q._cryptos[Epoch.ONE_RTT]
    header=bytes([0x43|(keys.key_phase<<2)])+q._peer_cid.cid+pn.to_bytes(4,'big')
    data=keys.send.encrypt_packet(header,b'\x01\x00\x00\x00',pn)
    return data[:-1]+bytes([data[-1]^1])

async def client_pool(args,report):
    server=await serve('127.0.0.1',0,configuration=config(args,False),
        create_protocol=ActivePeer if args.mode=='client-authenticated' else Peer)
    process=None
    try:
        port=server._transport.get_extra_info('sockname')[1]
        process=await asyncio.create_subprocess_exec(args.binary,'client',str(port),args.cert,
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        first=await line(process,b'RESPONSE ')
        remaining,pto,effective,negotiated=map(int,first[3:7])
        assert effective>=3*pto and negotiated==400 and remaining>0,first
        peer=PEERS[0]
        if args.mode=='client-authenticated':
            await peer.activity
            assert peer.activity_elapsed>effective/1000,(peer.activity_elapsed,effective)
            report.update(authenticated_pings=15,activity_seconds=peer.activity_elapsed)
        else:
            expiry=asyncio.get_running_loop().time()+remaining/1000+.1
            await at(expiry)
            terminal=await asyncio.wait_for(peer.terminal,8)
            assert terminal.reason_phrase=='Idle timeout',terminal
            report['peer_idle_reason']=terminal.reason_phrase
        process.stdin.write(b'r');await process.stdin.drain()
        second=await line(process,b'RESPONSE ')
        out,err=await asyncio.wait_for(process.communicate(),8)
        assert process.returncode==0 and not err,(out,err)
        expected=1 if args.mode=='client-authenticated' else 2
        assert len(PEERS)==expected and [p.calls for p in PEERS]==([2] if expected==1 else [1,1])
        if expected==2:assert PEERS[0]._quic.host_cid!=PEERS[1]._quic.host_cid
        report.update(first=first,second=second,native_stderr=err.decode(),peer_connections=expected)
    finally:
        if process and process.returncode is None:process.kill();await process.wait()
        server.close()

async def server_case(args,report):
    mode='saba' if args.mode=='saba-idle' else ('request-budget' if args.mode=='server-request-budget' else 'listener')
    process=await asyncio.create_subprocess_exec(args.binary,mode,args.cert,args.key,
        stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        fields=await line(process,b'READY ');port=int(fields[1]);cfg=config(args,True)
        async with connect('127.0.0.1',port,configuration=cfg,create_protocol=Peer) as peer:
            await peer.get()
            info=None if mode=='saba' else await timing(process)
            report['timing']=info
            loop=asyncio.get_running_loop();start=loop.time()
            if args.mode=='server-authenticated':
                assert info and info['remaining_ms']>0
                interval=min(info['remaining_ms']/1000,peer._quic._idle_timeout())*.25
                count=math.ceil(info['remaining_ms']/1000*1.4/interval)
                assert 5<=count<=100,count
                for i in range(count):
                    await at(start+(i+1)*interval)
                    await asyncio.wait_for(peer.ping(),3)
                after=await timing(process);assert after and int(after['remaining_ms'])>0
                await peer.get();report.update(pings=count,elapsed=loop.time()-start,after=after)
                calls=2
            elif args.mode=='server-request-budget':
                assert info and info['remaining_ms']>150
                # ACKs may shrink the native3PTO floor below the peer's RTT
                # estimate. Use their negotiated minimum to stay inside idle,
                # while exceeding the separate50ms application request budget.
                delay=min(info['remaining_ms'],info['negotiated_ms'])/1000*.4
                assert .05<delay<info['negotiated_ms']/1000
                await at(start+delay)
                current=await timing(process)
                assert current and current['remaining_ms']>0,current
                report.update(request_budget_wait_ms=round(delay*1000),timing_before_second=current)
                await peer.get();report['elapsed']=loop.time()-start;calls=2
            else:
                forged=[0]
                if args.mode=='server-forged':
                    assert info and info['remaining_ms']>0
                    packet=forged_ping(peer);address=peer._quic._network_paths[0].addr
                    limit=math.ceil((info['remaining_ms']/1000+2)/.01)
                    assert limit<=1000,limit
                    def inject():
                        peer._transport.sendto(packet,address);forged[0]+=1
                        if forged[0]<limit:timer_box[0]=loop.call_later(.01,inject)
                    timer_box=[None];inject()
                try:
                    if info:
                        await at(start+info['remaining_ms']/1000+.1)
                        after=await timing(process);assert after is None,after
                        if args.mode=='server-forged':
                            assert 0<forged[0]<limit,(forged[0],limit)
                            report['forged_active_at_expiry']=True
                            report['forged_destination_cid']=peer._quic._peer_cid.cid.hex()
                    else:
                        terminal=await asyncio.wait_for(peer.terminal,8)
                        assert terminal.reason_phrase=='Idle timeout',terminal
                    if args.mode!='server-forged':
                        terminal=await asyncio.wait_for(peer.terminal,8)
                        assert terminal.reason_phrase=='Idle timeout',terminal
                        report['peer_idle_reason']=terminal.reason_phrase
                    # The same one-slot listener must admit a fresh trusted peer.
                    async with connect('127.0.0.1',port,configuration=cfg,create_protocol=Peer) as fresh:
                        await fresh.get()
                    report.update(forged_datagrams=forged[0],recovery_seconds=loop.time()-start)
                finally:
                    if args.mode=='server-forged' and timer_box[0]:timer_box[0].cancel()
                calls=2
        report['native']=await finish(process,calls)
    finally:
        if process.returncode is None:process.kill();await process.wait()

async def pending_request_case(args, report):
    process = await asyncio.create_subprocess_exec(
        args.binary, 'saba-pending', args.cert, args.key,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    try:
        port = int((await line(process, b'READY '))[1])
        cfg = config(args, True)
        cfg.idle_timeout = 5
        async with connect('127.0.0.1', port, configuration=cfg,
                           create_protocol=Peer) as peer:
            stream = peer._quic.get_next_available_stream_id()
            started = asyncio.get_running_loop().time()
            peer.http.send_headers(stream, [(b':method', b'GET'), (b':scheme', b'https'),
                (b':authority', b'localhost'), (b':path', b'/probe')], end_stream=True)
            peer.transmit()
            terminal = await asyncio.wait_for(asyncio.shield(peer.terminal), 3)
            elapsed = asyncio.get_running_loop().time() - started
            assert terminal.error_code == 0x10c, terminal
            assert .1 < elapsed < 3, elapsed
            assert peer.events.empty(), 'pending handler produced an HTTP response'
            report.update(application_close_code=terminal.error_code,
                          pending_seconds=elapsed, request_timeout_ms=200)
        report['native'] = await finish(process, 1)
        assert 'RESULT calls=1 drops=1' in report['native']['stdout'], report
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()

async def run(args):
    assert aioquic.__version__=='1.3.0'
    report=dict(case=args.mode,peer='aioquic '+aioquic.__version__)
    if args.mode == 'saba-request-timeout': await pending_request_case(args, report)
    elif args.mode.startswith('client-'):await client_pool(args,report)
    else:await server_case(args,report)
    print(json.dumps(report))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode');p.add_argument('--binary',required=True)
    p.add_argument('--cert',required=True);p.add_argument('--key',required=True)
    asyncio.run(run(p.parse_args()))
