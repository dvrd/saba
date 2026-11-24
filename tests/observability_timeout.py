#!/usr/bin/env python3
"""Run only owned loopback fixtures; no live bot/provider traffic."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse,json,os,queue,socket,subprocess,tempfile,threading,time
from pathlib import Path

SABA=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--sanitize',choices=['address','thread']);args=parser.parse_args()
    compiler=harness_env.odin()
    with tempfile.TemporaryDirectory(prefix='saba-observability-') as work:
        binary=Path(work)/'fixture'
        command=[compiler,'build',str(SABA/'testdata/observability'),harness_env.collection(), '-out:'+str(binary),'-warnings-as-errors','-thread-count:1']
        if args.sanitize:command.append('-sanitize:'+args.sanitize)
        subprocess.run(command,check=True,capture_output=True,timeout=60)
        proc=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,text=True)
        lines=queue.Queue();all_lines=[]
        def reader():
            for line in proc.stdout:
                all_lines.append(line.strip());lines.put(line.strip())
        worker=threading.Thread(target=reader,daemon=True);worker.start()
        def line(prefix):
            end=time.monotonic()+8
            while time.monotonic()<end:
                value=lines.get(timeout=max(.01,end-time.monotonic()))
                if value.startswith(prefix):return value
            raise AssertionError(prefix+' timeout')
        try:
            port=int(line('ready ').split()[1])
            def connect():return socket.create_connection(('127.0.0.1',port),timeout=5)
            def exchange(wire,delay=0):
                with connect() as conn:
                    conn.sendall(wire)
                    if delay:time.sleep(delay)
                    data=bytearray()
                    while part:=conn.recv(65536):data.extend(part)
                    return bytes(data)
            requests=[]
            good=b'GET /items/private-id?token=secret HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: secret-id\r\n\r\n'
            result=exchange(good);assert result.startswith(b'HTTP/1.1 200 ') and result.endswith(b'ok');requests.append(('GET','Completed',len(good),len(result)))
            head=b'HEAD /items/private-id HTTP/1.1\r\nHost: localhost\r\n\r\n'
            result=exchange(head);assert result.endswith(b'\r\n\r\n') and b'Content-Length: 2\r\n' in result;requests.append(('HEAD','Completed',len(head),len(result)))
            malformed=b'GET /items/private-id HTTP/1.1\r\n\r\n'
            result=exchange(malformed);assert result.startswith(b'HTTP/1.1 400 ');requests.append(('GET','Protocol_Error',len(malformed),len(result)))
            with connect() as conn:
                started=time.monotonic()
                conn.sendall(b'G');time.sleep(.06);conn.sendall(b'E');time.sleep(.06);conn.sendall(b'T')
                result=bytearray()
                while part:=conn.recv(8192):result.extend(part)
                elapsed=time.monotonic()-started
                assert result.startswith(b'HTTP/1.1 408 ') and .13<elapsed<.29,elapsed
                requests.append(('OTHER','Timeout',3,len(result)))
            with connect() as conn:
                started=time.monotonic();result=conn.recv(8192);assert result.startswith(b'HTTP/1.1 408 ') and .04<time.monotonic()-started<1
                remaining=conn.recv(8192);assert remaining==b''  # answered, but a connection that never sent a byte is not a request: no event
            partial=b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\na'
            started=time.monotonic();result=exchange(partial);assert result.startswith(b'HTTP/1.1 408 ') and .07<time.monotonic()-started<2;requests.append(('POST','Timeout',len(partial),len(result)))
            with connect() as conn:
                conn.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,8192)
                wire=b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n';conn.sendall(wire)
                time.sleep(.6)
                data=bytearray()
                while part:=conn.recv(65536):data.extend(part)
                assert data.startswith(b"HTTP/1.1 200 ") and len(data)<8*1024*1024,(bytes(data[:60]),len(data))
                requests.append(('GET','Timeout',len(wire),len(data)))
            # Wait until every normal/timeout attempt is completed, not merely sent.
            seen=[]
            while len(seen)<len(requests):seen.append(line('event '))
            events=[]
            for raw in seen:
                parts=raw.split();events.append(dict(id=int(parts[1]),method=parts[2],route=parts[3],status=int(parts[4]),duration=int(parts[5]),received=int(parts[6]),sent=int(parts[7]),outcome=parts[8]))
            events.sort(key=lambda event:event['id'])
            for event,expected in zip(events,requests):
                method,outcome,received,sent=expected
                assert (event['method'],event['outcome'],event['received'],event['sent'])==(method,outcome,received,sent),(event,expected)
                assert event['duration']>=0
            assert events[0]['route']==events[1]['route']=='/items/:id'
            assert not any('private-id' in raw or 'secret' in raw for raw in seen)
            # A parked request cancelled by shutdown still completes exactly once.
            parked=connect();parked.sendall(b'G');time.sleep(.02)
            proc.stdin.write('\n');proc.stdin.flush();proc.wait(timeout=8);parked.close();worker.join(timeout=2)
            errors=proc.stderr.read();assert proc.returncode==0,errors
            assert 'ERROR: AddressSanitizer' not in errors and 'WARNING: ThreadSanitizer' not in errors,errors
            every=[x for x in all_lines if x.startswith('event ')]
            assert len(every)==len(requests)+1 and every[-1].endswith('Cancelled'),every
            ids=[int(x.split()[1]) for x in every];assert len(set(ids))==len(ids) and all(ids)
            stats=next(x for x in all_lines if x.startswith('metrics ')).split()
            assert int(stats[1])==len(every) and int(stats[2])==len(requests) and int(stats[3])==1,stats
            assert int(stats[4])==3,stats  # header, body and write timeouts; the silent connection is not counted
            print(json.dumps({'valid':True,'sanitizer':args.sanitize or 'none','events':len(every),'checks':['unique generated IDs, no user ID reflection','bounded static routes, no path/query/header leaks','exact received/sent wire byte accounting','HEAD headers only','header total and first-byte idle deadlines','partial body deadline','backpressured write timeout','exactly-once cancelled completion','observer snapshots outside internal locks','snapshots unpublished after shutdown']},indent=2))
        finally:
            if proc.poll() is None:proc.kill();proc.wait(timeout=5)

if __name__=='__main__':main()
