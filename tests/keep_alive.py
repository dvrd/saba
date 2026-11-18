#!/usr/bin/env python3
"""Public bounded persistence regression; all sockets/processes are test-owned."""
import argparse,concurrent.futures,contextlib,json,os,queue,socket,subprocess,tempfile,threading,time
from pathlib import Path
SABA=Path(__file__).resolve().parents[1]
CHECKS=[]

class Server:
    def __init__(self,binary,**settings):
        env=os.environ.copy();env.update({"SABA_KEEP_"+k.upper():str(v) for k,v in settings.items()})
        self.proc=subprocess.Popen([str(binary)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,text=True)
        self.lines=[];self.pending=queue.Queue();self.finished=False
        def read():
            for raw in self.proc.stdout:
                line=raw.strip();self.lines.append(line);self.pending.put(line)
        self.reader=threading.Thread(target=read,daemon=True);self.reader.start()
        try:self.port=int(self.wait('ready ').split()[1])
        except BaseException:
            if self.proc.poll() is None:self.proc.kill()
            self.proc.wait(timeout=5);self.reader.join(timeout=2)
            for pipe in [self.proc.stdin,self.proc.stdout,self.proc.stderr]:pipe.close()
            raise
    def wait(self,prefix):
        end=time.monotonic()+8
        while time.monotonic()<end:
            line=self.pending.get(timeout=max(.01,end-time.monotonic()))
            if line.startswith(prefix):return line
        raise AssertionError(prefix+' timeout')
    def connect(self):return socket.create_connection(('127.0.0.1',self.port),timeout=5)
    def drain(self):
        self.proc.stdin.write('d');self.proc.stdin.flush();self.wait('draining')
    def finish(self,mode='s'):
        if self.finished:return
        if mode is not None:self.proc.stdin.write(mode);self.proc.stdin.flush()
        self.proc.wait(timeout=8);self.reader.join(timeout=2);self.finished=True
        error=self.proc.stderr.read();assert self.proc.returncode==0,error
        assert 'ERROR: AddressSanitizer' not in error and 'WARNING: ThreadSanitizer' not in error,error
        stopped=next(x for x in self.lines if x.startswith('stopped '))
        events=self.events();assert int(stopped.split()[1])==len(events),self.lines
        assert len({e['id'] for e in events})==len(events) and all(e['id'] for e in events)
    def events(self):
        result=[]
        for raw in self.lines:
            if not raw.startswith('event '):continue
            p=raw.split();result.append(dict(id=int(p[1]),method=p[2],route=p[3],status=int(p[4]),received=int(p[5]),sent=int(p[6]),outcome=p[7]))
        return sorted(result,key=lambda e:e['id'])
    def __enter__(self):return self
    def __exit__(self,kind,value,tb):
        if kind is None:self.finish()
        elif self.proc.poll() is None:self.proc.kill();self.proc.wait(timeout=5)


def request(path='/id',method='GET',body=b'',fields=b''):
    return method.encode()+b' '+path.encode()+b' HTTP/1.1\r\nHost: localhost\r\n'+(b'Content-Length: '+str(len(body)).encode()+b'\r\n' if body or method=='POST' else b'')+fields+b'\r\n'+body

def exact(conn,count):
    result=bytearray()
    while len(result)<count:
        data=conn.recv(count-len(result));assert data,'unexpected EOF';result.extend(data)
    return bytes(result)

def response(conn,head_only=False):
    head=bytearray()
    while not head.endswith(b'\r\n\r\n'):
        head.extend(exact(conn,1));assert len(head)<=8192
    status=int(head.split(b' ',2)[1]);length=0
    for line in head.split(b'\r\n'):
        if line.lower().startswith(b'content-length:'):length=int(line.split(b':',1)[1])
    body=b'' if head_only else exact(conn,length)
    return status,bytes(head),body

def closed(conn):
    try:assert conn.recv(1)==b''
    except ConnectionResetError:pass

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--sanitize',choices=['address','thread']);parser.add_argument('--core',action='store_true',help='exercise identical corpus through lean core');args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-keepalive-') as work:
        binary=Path(work)/'fixture';command=[os.environ['ODIN'],'build',str(SABA/('tests/core/testdata/keepalive' if args.core else 'testdata/keepalive')),'-out:'+str(binary),'-thread-count:1','-warnings-as-errors']
        if args.sanitize:command.append('-sanitize:'+args.sanitize)
        built=subprocess.run(command,capture_output=True,text=True,timeout=90);assert built.returncode==0,built.stdout+built.stderr
        # Disabled means the next already-buffered request is never admitted.
        with Server(binary,disabled=1) as s:
            with s.connect() as conn:
                conn.sendall(request()+request());status,head,body=response(conn);assert status==200 and b'Connection: close\r\n' in head;closed(conn)
            s.finish();assert len(s.events())==1
        CHECKS.append('default disabled preserves close, including unread pipelined requests')
        # Same socket: body framing, HEAD and fresh IDs/state for successive requests.
        with Server(binary,idle_ms=500) as s:
            expected=[];received=[]
            with s.connect() as conn:
                for wire,head_only in [(request('/id'),False),(request('/echo','POST',b'body'),False),(request('/id','HEAD'),True),(request('/id'),False)]:
                    conn.sendall(wire);status,head,body=response(conn,head_only);assert status==200 and b'Connection: keep-alive\r\n' in head
                    expected.append(len(wire));received.append(len(head)+len(body))
                conn.shutdown(socket.SHUT_WR);closed(conn)
            s.finish();events=s.events();assert len(events)==4
            assert [e['received'] for e in events]==expected and [e['sent'] for e in events]==received
        CHECKS.append('sequential requests reset IDs/body state, HEAD semantics and exact consumed-byte metrics; EOF adds no event')
        # Coalesced requests with a preceding body cannot consume the next message.
        with Server(binary,idle_ms=500) as s:
            wires=[request('/echo','POST',b'abc'),request('/id'),request('/id',fields=b'Connection: close\r\n')]
            with s.connect() as conn:
                conn.sendall(b''.join(wires));answers=[response(conn) for _ in wires]
                assert answers[0][2]==b'abc' and answers[1][2]!=answers[2][2]
                assert b'Connection: close\r\n' in answers[-1][1];closed(conn)
            s.finish();events=s.events();assert len(events)==3
            assert [e['received'] for e in events]==[len(w) for w in wires]
            assert [e['sent'] for e in events]==[len(h)+len(b) for _,h,b in answers]
        CHECKS.append('coalesced body/pipeline boundaries are serial and attributed to the correct request')
        # Larger than initial512 byte head and fragmented requests survive reset.
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                first=request('/id',fields=b'X-Pad: '+b'x'*6000+b'\r\n');next_wire=request('/id',fields=b'Connection: close\r\n')
                conn.sendall(first+next_wire[:7]);assert response(conn)[0]==200
                conn.sendall(next_wire[7:]);assert response(conn)[0]==200;closed(conn)
            s.finish();assert len(s.events())==2
        CHECKS.append('grown header storage preserves a fragmented next request across arena reset')
        # Old1MiB response blocks must be gone before the next handler starts.
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                for _ in range(5):
                    conn.sendall(request('/allocate')+request('/arena'))
                    assert len(response(conn)[2])==1024*1024 and response(conn)[0]==200
                conn.shutdown(socket.SHUT_WR);closed(conn)
            s.finish();assert len(s.events())==10
        CHECKS.append('request arena out-of-band allocations are released between large responses and next handlers')
        with Server(binary,max=3,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request()*4)
                for n in range(3):
                    status,head,_=response(conn);assert status==200
                    assert (b'Connection: close\r\n' in head)==(n==2)
                closed(conn)
            s.finish();assert len(s.events())==3
        CHECKS.append('max_requests advertises close on the last response and never dispatches an extra pipeline request')
        for path,field in [('/id',b'cOnNeCtIoN: upgrade, cLoSe\r\n'),('/close',b''),('/id',b'Connection: keep-alive\r\nConnection: close\r\n')]:
            with Server(binary,idle_ms=500) as s:
                with s.connect() as conn:
                    conn.sendall(request(path,fields=field)+request());status,head,_=response(conn);assert status==200 and b'Connection: close\r\n' in head;closed(conn)
                s.finish();assert len(s.events())==1
        CHECKS.append('mixed-case comma-list/duplicate close tokens and handler-forced close end persistence')
        for bad,code in [(b'GET /id HTTP/1.1\r\n\r\n',400),(request('/limited','POST',b'12345'),413)]:
            with Server(binary,idle_ms=500) as s:
                with s.connect() as conn:
                    conn.sendall(request()+bad+request());assert response(conn)[0]==200
                    status,head,_=response(conn);assert status==code and b'Connection: close\r\n' in head;closed(conn)
                s.finish();assert len(s.events())==2
        CHECKS.append('malformed or over-limit next requests close safely with no parser/header/body state bleed')
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200
                wire=request('/echo','POST',b'abcdef');conn.sendall(wire[:-3]);conn.shutdown(socket.SHUT_WR)
                status,head,_=response(conn);assert status==400 and b'Connection: close\r\n' in head;closed(conn)
            s.finish();assert len(s.events())==2 and s.events()[-1]['outcome']=='Peer_Closed'
        CHECKS.append('EOF inside a subsequent body returns400, preserves partial-byte accounting and cannot reuse ambiguous framing')
        with Server(binary) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200
                start=time.monotonic();closed(conn);assert .04<time.monotonic()-start<.6
            s.finish();assert len(s.events())==1
        CHECKS.append('idle zero inherits the configured idle budget and closes silently without phantom completion')
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200;time.sleep(.25)
                conn.sendall(request(fields=b'Connection: close\r\n'));assert response(conn)[0]==200;closed(conn)
            s.finish();assert len(s.events())==2
        CHECKS.append('next header deadline starts on its first byte, independently of the preceding idle interval')
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200;conn.sendall(b'G')
                assert response(conn)[0]==408;closed(conn)
            s.finish();assert len(s.events())==2 and s.events()[-1]['outcome']=='Timeout'
        CHECKS.append('partial subsequent request uses its own total header deadline and closes on timeout')
        with Server(binary,idle_ms=500,capacity=2) as s:
            one,two=s.connect(),s.connect()
            for conn in [one,two]:conn.sendall(request());assert response(conn)[0]==200
            with s.connect() as extra:assert response(extra)[0]==503;closed(extra)
            one.close();time.sleep(.02)
            with s.connect() as extra:extra.sendall(request(fields=b'Connection: close\r\n'));assert response(extra)[0]==200;closed(extra)
            two.close();s.finish();assert len(s.events())==3
        CHECKS.append('idle connections remain bounded by admission capacity and overload recovers after close')
        # Drain promptly wakes idle sockets rather than waiting on a polling tick.
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200
                start=time.monotonic();s.drain();closed(conn);assert time.monotonic()-start<.2
            s.finish(None);assert len(s.events())==1
        CHECKS.append('drain wakes idle sockets promptly, releases registration and emits no duplicate event')
        # A second request already admitted before drain may finish its body.
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request());assert response(conn)[0]==200
                wire=request('/echo','POST',b'abcdef');conn.sendall(wire[:-3]);time.sleep(.02);s.drain();conn.sendall(b'def')
                status,head,body=response(conn);assert status==200 and body==b'abcdef' and b'Connection: close\r\n' in head;closed(conn)
            s.finish(None);assert len(s.events())==2 and all(e['outcome']=='Completed' for e in s.events())
        CHECKS.append('drain preserves an already admitted partial-body request then closes instead of admitting another')
        with Server(binary,idle_ms=500) as s:
            with s.connect() as conn:
                conn.sendall(request('/drain')+request());status,head,_=response(conn);assert status==200 and b'Connection: close\r\n' in head;closed(conn)
            s.finish('j');assert len(s.events())==1
        CHECKS.append('handler-initiated drain rejects unread pipelined requests after the current response')
        with Server(binary,idle_ms=500,observer_drain=1) as s:
            with s.connect() as conn:
                conn.sendall(request()+request());status,head,_=response(conn)
                assert status==200 and b'Connection: keep-alive\r\n' in head;closed(conn)
            s.finish('j');assert len(s.events())==1
        CHECKS.append('completion-observer drain safely closes advertised persistence before unread pipeline admission')
        with Server(binary,idle_ms=500) as s:
            conn=s.connect();conn.sendall(request());assert response(conn)[0]==200
            s.finish();closed(conn);conn.close();assert len(s.events())==1
        CHECKS.append('immediate shutdown closes idle persistence without a new request or leaked task')
        with Server(binary,idle_ms=500) as s:
            sockets=[s.connect() for _ in range(12)]
            for conn in sockets:conn.sendall(request());assert response(conn)[0]==200
            def next_request(conn):
                try:
                    conn.sendall(request('/slow'));status,_,_=response(conn);assert status==200
                    closed(conn)
                except AssertionError as error:
                    if str(error) != 'unexpected EOF':raise
                except (ConnectionError,OSError):pass
                finally:conn.close()
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
                futures=[executor.submit(next_request,conn) for conn in sockets]
                time.sleep(.01);s.drain()
                for future in futures:future.result(timeout=5)
            s.finish(None);events=s.events();assert len(events)>=12 and all(e['outcome']=='Completed' for e in events)
        CHECKS.append('concurrent next-request admission races drain without idle-list lifetime leaks or duplicate IDs')
    print(json.dumps({'valid':True,'sanitizer':args.sanitize or 'none','checks':CHECKS},indent=2))

if __name__=='__main__':main()
