#!/usr/bin/env python3
"""Raw GOAWAY observer/injector over independent aioquic QUIC/H3 and wsproto.
The pinned aioquic release ignores GOAWAY itself; this hook validates it explicitly.
"""
import argparse,asyncio,importlib.util,ssl
from pathlib import Path
from aioquic.asyncio import connect,serve
from aioquic.h3.connection import H3Connection,FrameType,encode_frame
from aioquic.buffer import Buffer,encode_uint_var
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated,StreamReset
from aioquic.h3.events import HeadersReceived,DataReceived
import wsproto,wsproto.events as events
spec=importlib.util.spec_from_file_location('connect_peer',Path(__file__).parents[1]/'http3_connect/peer.py');base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
MODE='observe'
class HTTP(H3Connection):
 def __init__(self,*a,**kw):super().__init__(*a,**kw);self.goaways=[]
 def _handle_control_frame(self,kind,payload):
  if kind==FrameType.GOAWAY:
   b=Buffer(data=payload);value=b.pull_uint_var();assert b.eof()
   assert not self._is_client or value%4==0
   assert not self.goaways or value<=self.goaways[-1]
   self.goaways.append(value);print('GOAWAY',value,flush=True)
  return super()._handle_control_frame(kind,payload)
base.HTTP=HTTP
class Peer(base.Peer):
 def __init__(self,*a,**kw):super().__init__(*a,**kw);self.resets=asyncio.Queue();self.close_code=None
 def quic_event_received(self,event):
  if isinstance(event,ConnectionTerminated):self.close_code=event.error_code;print('CLOSE',event.error_code,flush=True)
  if isinstance(event,StreamReset):self.resets.put_nowait(event)
  if not self.server:return super().quic_event_received(event)
  for e in self.http.handle_event(event):
   if isinstance(e,HeadersReceived):
    h=dict(e.headers);path=h.get(b':path');method=h.get(b':method')
    if MODE=='reject' and method==b'POST':
     print('POST ONCE',flush=True);self.goaway(0);continue
    if MODE in ('wrong-id','increasing','trailing'):
     if MODE=='wrong-id':self.goaway(1)
     elif MODE=='increasing':self.goaway((1<<62)-4);self.goaway(8);self.goaway(12)
     else:self._quic.send_stream_data(self.http._local_control_stream_id,encode_frame(7,b'\x00\x00'))
     self.transmit();continue
    if MODE=='decreasing':self.goaway((1<<62)-4);self.goaway(8);self.goaway(4)
    if method==b'CONNECT':
     self.sockets[e.stream_id]=wsproto.Connection(wsproto.ConnectionType.SERVER)
     self.http.send_headers(e.stream_id,[(b':status',b'200'),(b'sec-websocket-protocol',b'chat.v2')])
    else:self.http.send_headers(e.stream_id,[(b':status',b'200')]);self.http.send_data(e.stream_id,b'http-ok',end_stream=True)
   elif isinstance(e,DataReceived) and e.stream_id in self.sockets:
    sock=self.sockets[e.stream_id];sock.receive_data(e.data)
    for w in sock.events():
     if isinstance(w,(events.TextMessage,events.BytesMessage)):self.http.send_data(e.stream_id,sock.send(w),end_stream=False)
     elif isinstance(w,events.Ping):self.http.send_data(e.stream_id,sock.send(w.response()),end_stream=False)
     elif isinstance(w,events.CloseConnection):self.http.send_data(e.stream_id,sock.send(w.response()),end_stream=True);self.sockets.pop(e.stream_id,None)
   self.transmit()
 def goaway(self,value):self._quic.send_stream_data(self.http._local_control_stream_id,encode_frame(7,encode_uint_var(value)));self.transmit()
 async def get_path(self,path):
  i=self._quic.get_next_available_stream_id();self.http.send_headers(i,[(b':method',b'GET'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',path)],end_stream=True);self.transmit()
  h,_=await self.headers(i);assert h[b':status']==b'200';body=b''
  while True:
   e=await asyncio.wait_for(self.queue(i).get(),8)
   if isinstance(e,DataReceived):
    body+=e.data
    if e.stream_ended:break
  assert body==b'http-ok'
class Relay(asyncio.DatagramProtocol):
 def __init__(self,server):self.server=server;self.client=None;self.armed=False;self.dropped=0
 def connection_made(self,transport):self.transport=transport
 def datagram_received(self,data,addr):
  if addr==self.server:
   if self.armed and not self.dropped and data[0]&0x80==0:self.dropped+=1;print('DROPPED shutdown datagram',flush=True);return
   if self.client:self.transport.sendto(data,self.client)
  else:self.client=addr;self.transport.sendto(data,self.server)
async def main(a):
 global MODE;MODE=a.mode
 cfg=QuicConfiguration(is_client=a.mode=='observe',alpn_protocols=['h3'])
 if a.mode=='observe':
  loop=asyncio.get_running_loop();relay=Relay(('127.0.0.1',a.port));transport,_=await loop.create_datagram_endpoint(lambda:relay,local_addr=('127.0.0.1',0));port=transport.get_extra_info('sockname')[1]
  cfg.verify_mode=ssl.CERT_NONE
  try:
   async with connect('127.0.0.1',port,configuration=cfg,create_protocol=Peer) as p:
    ws=await p.websocket();cancelled=await p.websocket();await asyncio.sleep(.1);relay.armed=True
    await p.get_path(b'/drain');assert p.http.goaways and p.http.goaways[-1]==12
    p.goaway(3);p.goaway(0)
    p._quic.reset_stream(cancelled,0x10c);p._quic.stop_stream(cancelled,0x10c);p.transmit()
    assert await p.exchange(ws,events.TextMessage(data='shutdown-live'),events.TextMessage)=='shutdown-live'
    i=p._quic.get_next_available_stream_id();assert i==12
    p.http.send_headers(i,[(b':method',b'GET'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/health')],end_stream=True);p.transmit()
    while True:
     reset=await asyncio.wait_for(p.resets.get(),8)
     if reset.stream_id==i:assert reset.error_code==0x10b,reset;break
     assert reset.stream_id==cancelled and reset.error_code==0x10c,reset
    await p.close_socket(ws);await asyncio.wait_for(p.wait_closed(),8);assert p.close_code==0x100,p.close_code
    assert relay.dropped==1;print('OK GOAWAY loss, live WS, request rejection and H3_NO_ERROR',flush=True)
  finally:transport.close()
 else:
  cfg.load_cert_chain(a.cert,a.key);server=await serve('127.0.0.1',a.port,configuration=cfg,create_protocol=Peer)
  print('READY',a.port,flush=True)
  try:await asyncio.Event().wait()
  finally:server.close()
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['observe','reject','wrong-id','increasing','trailing','decreasing','graceful']);p.add_argument('port',type=int);p.add_argument('--cert');p.add_argument('--key');asyncio.run(main(p.parse_args()))
