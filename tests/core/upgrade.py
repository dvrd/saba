#!/usr/bin/env python3
import argparse,json,os,queue,socket,struct,subprocess,tempfile,threading
from pathlib import Path
CORE=Path(__file__).resolve().parents[2]/'core'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--sanitize',choices=['address','thread']);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='saba-core-upgrade-') as work:
        binary=Path(work)/'fixture';cmd=[os.environ['ODIN'],'build',str(CORE/'testdata/upgrade'),'-out:'+str(binary),'-warnings-as-errors','-thread-count:1']
        if args.sanitize:cmd.append('-sanitize:'+args.sanitize)
        built=subprocess.run(cmd,capture_output=True,text=True,timeout=60);assert built.returncode==0,built.stdout+built.stderr
        proc=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        lines=queue.Queue()
        def reader():
            for raw in proc.stdout:lines.put(raw.strip())
        worker=threading.Thread(target=reader,daemon=True);worker.start()
        def wait(prefix):
            while True:
                line=lines.get(timeout=8)
                if line.startswith(prefix):return line
        def connect():return socket.create_connection(('127.0.0.1',port),timeout=5)
        def request(path):return b'GET '+path.encode()+b' HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: raw-echo\r\n\r\n'
        def headers(conn):
            out=bytearray()
            while not out.endswith(b'\r\n\r\n'):
                part=conn.recv(1);assert part;out.extend(part)
            assert out.startswith(b'HTTP/1.1 101 '),out
        def exact(conn,count):
            out=bytearray()
            while len(out)<count:
                part=conn.recv(count-len(out));assert part;out.extend(part)
            return out
        try:
            port=int(wait('ready ').split()[1])
            for path,early in [('/echo',b'abcde'),('/echo',b'ab')]:
                with connect() as conn:
                    conn.sendall(request(path)+early);wait('created ');headers(conn)
                    if len(early)<5:conn.sendall(b'cde')
                    assert exact(conn,5)==b'abcde' and conn.recv(1)==b''
                    assert int(wait('dropped ').split()[2])>0
            with connect() as conn:
                conn.sendall(request('/stateless'));headers(conn);assert conn.recv(1)==b''
            for path in ['/reject','/badheader','/missingprotocol','/emptyprotocol']:
                with connect() as conn:
                    conn.sendall(request(path));wait('created ');assert conn.recv(1)==b''
                    assert wait('dropped ').endswith(' 0')
            conn=connect();conn.sendall(request('/writefail'));wait('created ')
            conn.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));conn.close()
            assert wait('dropped ').endswith(' 0'),'response write must fail before resume'
            conn=connect();conn.sendall(request('/cancel'));wait('created ');headers(conn)
            proc.stdin.write('s');proc.stdin.flush();proc.wait(timeout=8);conn.close();worker.join(timeout=2)
            final=wait('finished ');assert final=='finished 8 8',final
            error=proc.stderr.read();assert proc.returncode==0,error
            assert 'ERROR: AddressSanitizer' not in error and 'WARNING: ThreadSanitizer' not in error,error
            print(json.dumps({'valid':True,'sanitizer':args.sanitize or 'none','owned_sessions':8,'checks':['coalesced prefetched bytes survive HTTP arena release','fragmented raw upgrade echo remains on current task','stateless continuation without destructor','non101 continuation rejected and dropped','invalid101 headers dropped','missing101 protocol dropped without resume','whitespace-only101 protocol dropped without resume','peer reset before101 write drops without resume','shutdown cancels pending upgraded IO and drops once']},indent=2))
        finally:
            if proc.poll() is None:proc.kill();proc.wait(timeout=5)

if __name__=='__main__':main()
