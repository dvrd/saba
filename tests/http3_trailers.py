#!/usr/bin/env python3
"""Native Surf/Saba and pinned independent aioquic trailer wire fixtures."""
import argparse,importlib.util,json,os,socket,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent;SHARED=HERE.parents[1]
spec=importlib.util.spec_from_file_location('harness',HERE/'http2_connect.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
def main():
    p=argparse.ArgumentParser();p.add_argument('--odin',type=Path,required=True);p.add_argument('--sanitize',choices=['address','thread'],default='address');p.add_argument('--python',default='/tmp/webtools397-peer/bin/python');p.add_argument('--report',type=Path,required=True);a=p.parse_args()
    env=os.environ.copy();env['PATH']='/opt/homebrew/opt/llvm@22/bin:'+env['PATH']
    binary=Path(f'/tmp/webtools395-{a.sanitize}-{os.getpid()}');cert=HERE / 'testdata/tls/localhost.pem';key=HERE / 'testdata/tls/rsa2048.pem';peer=HERE/'http3_trailers/peer.py'
    records=[h.run([a.odin,'build',HERE/'http3_trailers',f'-collection:shared={SHARED}','-warnings-as-errors','-vet',f'-sanitize:{a.sanitize}',f'-out:{binary}'],env)]
    records+=h.exercise(binary,['server',cert,key],[lambda port:[binary,'client',port,cert],lambda port:[a.python,peer,'client',port,'--cert',cert]],env)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    server=subprocess.Popen([a.python,str(peer),'server',str(port),'--cert',str(cert),'--key',str(key)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
    try:
        line=server.stdout.readline();assert line.startswith('READY'),line
        records.append(h.run([binary,'client-bad',str(port),cert],env,20))
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        stderr=server.stderr.read();assert not stderr,stderr
    result=dict(passed=True,sanitizer=a.sanitize,peer='aioquic1.3.0',records=records);a.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
