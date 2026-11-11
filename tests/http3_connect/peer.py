#!/usr/bin/env python3
"""Pinned aioquic 1.3.0 / wsproto 1.2.0 independent RFC9220 peer."""
import argparse, asyncio, ssl
from aioquic.asyncio import connect, serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection, Setting
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import StreamReset,StopSendingReceived
import wsproto, wsproto.events as events

class HTTP(H3Connection):
    def _get_local_settings(self):
        settings=super()._get_local_settings()
        if MODE=='no-connect': settings.pop(Setting.ENABLE_CONNECT_PROTOCOL,None)
        if MODE=='invalid-setting': settings[Setting.ENABLE_CONNECT_PROTOCOL]=2
        return settings

MODE='server'
class Peer(QuicConnectionProtocol):
    def __init__(self,*a,**kw):
        super().__init__(*a,**kw);self.http=HTTP(self._quic);self.queues={};self.sockets={};self.server=not self._quic.configuration.is_client
    def queue(self,i):return self.queues.setdefault(i,asyncio.Queue())
    def quic_event_received(self,event):
        if self.server and isinstance(event,(StreamReset,StopSendingReceived)):
            assert event.error_code==0x10c,event
            if isinstance(event,StreamReset):self.sockets.pop(event.stream_id,None)
            print('RESET',event.error_code,flush=True)
        for e in self.http.handle_event(event):
            if not self.server:
                self.queue(e.stream_id).put_nowait(e);continue
            if isinstance(e,HeadersReceived):
                h=dict(e.headers)
                if h.get(b':method')==b'CONNECT':
                    assert MODE!='no-connect','CONNECT was sent without server permission'
                    assert h[b':protocol']==b'websocket' and h[b'sec-websocket-version']==b'13'
                    assert b'sec-websocket-key' not in h and not e.stream_ended
                    self.sockets[e.stream_id]=wsproto.Connection(wsproto.ConnectionType.SERVER)
                    self.http.send_headers(e.stream_id,[(b':status',b'200'),(b'sec-websocket-protocol',b'chat.v2')])
                else:
                    self.http.send_headers(e.stream_id,[(b':status',b'200')]);self.http.send_data(e.stream_id,b'http-ok',end_stream=True)
            elif isinstance(e,DataReceived) and e.stream_id in self.sockets:
                sock=self.sockets[e.stream_id];sock.receive_data(e.data)
                for w in sock.events():
                    if isinstance(w,(events.TextMessage,events.BytesMessage)):
                        self.http.send_data(e.stream_id,sock.send(w),end_stream=False)
                    elif isinstance(w,events.Ping):self.http.send_data(e.stream_id,sock.send(w.response()),end_stream=False)
                    elif isinstance(w,events.CloseConnection):
                        self.http.send_data(e.stream_id,sock.send(w.response()),end_stream=True);self.sockets.pop(e.stream_id,None)
            self.transmit()
    async def headers(self,i):
        while True:
            e=await asyncio.wait_for(self.queue(i).get(),8)
            if isinstance(e,HeadersReceived):return dict(e.headers),e.stream_ended
    async def get(self):
        i=self._quic.get_next_available_stream_id();self.http.send_headers(i,[(b':method',b'GET'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/health')],end_stream=True);self.transmit()
        h,_=await self.headers(i);assert h[b':status']==b'200';body=b''
        while True:
            e=await asyncio.wait_for(self.queue(i).get(),8)
            if isinstance(e,DataReceived):
                body+=e.data
                if e.stream_ended:break
        assert body==b'http-ok'
    async def rejected(self,origin=b'https://allowed.invalid',subprotocol=b'chat.v2',protocol=b'websocket',status=b'403'):
        i=self._quic.get_next_available_stream_id();self.http.send_headers(i,[(b':method',b'CONNECT'),(b':protocol',protocol),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/socket'),(b'sec-websocket-version',b'13'),(b'origin',origin),(b'sec-websocket-protocol',subprotocol)]);self.transmit()
        h,_=await self.headers(i);assert h[b':status']==status,h
        self._quic.reset_stream(i,0x10c);self.transmit()
    async def websocket(self):
        i=self._quic.get_next_available_stream_id();self.http.send_headers(i,[(b':method',b'CONNECT'),(b':protocol',b'websocket'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/socket'),(b'sec-websocket-version',b'13'),(b'origin',b'https://allowed.invalid'),(b'sec-websocket-protocol',b'chat.v2')]);self.transmit()
        h,ended=await self.headers(i);assert h[b':status']==b'200' and h[b'sec-websocket-protocol']==b'chat.v2' and not ended
        assert b'sec-websocket-accept' not in h and b'upgrade' not in h
        self.sockets[i]=wsproto.Connection(wsproto.ConnectionType.CLIENT);return i
    async def exchange(self,i,event,kind):
        sock=self.sockets[i];self.http.send_data(i,sock.send(event),end_stream=False);self.transmit();parts=[]
        while True:
            e=await asyncio.wait_for(self.queue(i).get(),8)
            if isinstance(e,DataReceived):
                sock.receive_data(e.data)
                for w in sock.events():
                    if isinstance(w,kind):
                        if hasattr(w,'data'):
                            parts.append(w.data)
                            if not w.message_finished:continue
                            return ('' if isinstance(w.data,str) else b'').join(parts)
                        if isinstance(w,events.Pong):return w.payload
                        return w
    async def close_socket(self,i):
        sock=self.sockets[i];self.http.send_data(i,sock.send(events.CloseConnection(code=1000)),end_stream=True);self.transmit()
        while True:
            e=await asyncio.wait_for(self.queue(i).get(),8)
            if isinstance(e,DataReceived):
                sock.receive_data(e.data)
                for w in sock.events():
                    if isinstance(w,events.CloseConnection):return

async def main(a):
    global MODE;MODE=a.mode
    cfg=QuicConfiguration(is_client=a.mode=='client',alpn_protocols=['h3'])
    if a.mode=='client':
        cfg.verify_mode=ssl.CERT_NONE
        async with connect('127.0.0.1',int(a.port),configuration=cfg,create_protocol=Peer) as p:
            await p.rejected(origin=b'https://denied.invalid')
            await p.rejected(subprotocol=b'unoffered',status=b'400')
            await p.rejected(protocol=b'unknown',status=b'501')
            first=await p.websocket();second=await p.websocket();await p.get()
            assert await p.exchange(first,events.TextMessage(data='independent'),events.TextMessage)=='independent'
            assert await p.exchange(first,events.Ping(payload=b'ping'),events.Pong)==b'ping'
            payload=bytes(i%251 for i in range(128*1024))
            assert await p.exchange(first,events.BytesMessage(data=payload),events.BytesMessage)==payload
            await p.close_socket(first)
            assert await p.exchange(second,events.TextMessage(data='survivor'),events.TextMessage)=='survivor'
            p._quic.reset_stream(second,0x10c);p._quic.stop_stream(second,0x10c);p.transmit();await p.get()
            print('OK independent RFC9220 client')
    else:
        cfg.load_cert_chain(a.cert,a.key)
        server=await serve('127.0.0.1',int(a.port),configuration=cfg,create_protocol=Peer)
        print('READY',a.port,flush=True)
        try:await asyncio.Event().wait()
        finally:server.close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['client','server','no-connect','invalid-setting']);p.add_argument('port');p.add_argument('--cert');p.add_argument('--key');asyncio.run(main(p.parse_args()))
