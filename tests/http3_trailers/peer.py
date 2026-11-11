"""Independent aioquic HTTP3 trailer peer; all traffic is test-owned loopback."""
import argparse,asyncio
from aioquic.asyncio import connect,serve,QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import HeadersReceived,DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import StreamReset,ConnectionTerminated

class Peer(QuicConnectionProtocol):
    server_connections=0
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        if not self._quic.configuration.is_client:
            Peer.server_connections+=1;assert Peer.server_connections==1,'message error closed the pooled connection'
        self.h3=H3Connection(self._quic);self.waiters={};self.messages={}
    def quic_event_received(self,event):
        if isinstance(event,StreamReset):
            future=self.waiters.pop(event.stream_id,None)
            if future and not future.done():future.set_result(('reset',event.error_code))
        if isinstance(event,ConnectionTerminated):
            for future in self.waiters.values():
                if not future.done():future.set_exception(RuntimeError(f'connection terminated {event.error_code}'))
        for item in self.h3.handle_event(event):
            if not isinstance(item,(HeadersReceived,DataReceived)):continue
            message=self.messages.setdefault(item.stream_id,dict(headers=[],body=b''))
            if isinstance(item,HeadersReceived):message['headers'].append(item.headers)
            else:message['body']+=item.data
            if item.stream_ended:
                if self._quic.configuration.is_client:
                    future=self.waiters.pop(item.stream_id,None)
                    if future and not future.done():future.set_result(('message',message))
                else:
                    path=dict(message['headers'][0]).get(b':path')
                    if path!=b'/bad':
                        assert message['headers'][-1]==[(b'x-request-checksum',b'abc')],message
                        assert message['body'] in (b'',b'payload')
                    self.h3.send_headers(item.stream_id,[(b':status',b'200'),(b'content-length',b'4')])
                    self.h3.send_data(item.stream_id,b'echo',end_stream=False)
                    trailer=[(b'content-length',b'4')] if path==b'/bad' else [(b'x-response-checksum',b'ack')]
                    self.h3.send_headers(item.stream_id,trailer,end_stream=True);self.transmit()
    async def request(self,body=b'',bad=False):
        stream=self._quic.get_next_available_stream_id();future=asyncio.get_running_loop().create_future();self.waiters[stream]=future
        self.h3.send_headers(stream,[(b':method',b'POST'),(b':scheme',b'https'),(b':authority',b'localhost'),(b':path',b'/trailers'),(b'host',b'evil.invalid'),(b'content-length',str(len(body)).encode())])
        if body:self.h3.send_data(stream,body,end_stream=False)
        self.h3.send_headers(stream,[(b'content-length',b'9')] if bad else [(b'x-request-checksum',b'abc')],end_stream=True)
        self.transmit();return await asyncio.wait_for(future,5)

async def main(args):
    configuration=QuicConfiguration(is_client=args.mode=='client',alpn_protocols=['h3'])
    if args.mode=='client':
        configuration.load_verify_locations(args.cert);configuration.server_name='localhost'
        async with connect('127.0.0.1',args.port,configuration=configuration,create_protocol=Peer) as peer:
            for body in (b'payload',b''):
                kind,message=await peer.request(body);assert kind=='message',message
                assert len(message['headers'])==2 and dict(message['headers'][0])[b':status']==b'200'
                assert message['headers'][1]==[(b'x-response-checksum',b'ack')] and message['body']==b'echo'
            kind,code=await peer.request(b'payload',bad=True);assert kind=='reset' and code==0x10e,(kind,code)
            kind,message=await peer.request(b'payload');assert kind=='message' and message['body']==b'echo'
        print('OK independent trailers and malformed-stream isolation',flush=True)
    else:
        configuration.load_cert_chain(args.cert,args.key)
        server=await serve('127.0.0.1',args.port,configuration=configuration,create_protocol=Peer)
        print('READY',flush=True)
        try:await asyncio.Event().wait()
        finally:server.close()
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode');parser.add_argument('port',type=int);parser.add_argument('--cert',required=True);parser.add_argument('--key');asyncio.run(main(parser.parse_args()))
