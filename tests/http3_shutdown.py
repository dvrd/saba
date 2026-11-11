#!/usr/bin/env python3
import argparse,importlib.util,json,os,socket,subprocess,time,threading,queue
from pathlib import Path
HERE=Path(__file__).resolve().parent;SHARED=HERE.parents[1]
spec=importlib.util.spec_from_file_location('harness',HERE/'http2_connect.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
def main():
 p=argparse.ArgumentParser();p.add_argument('--odin',type=Path,required=True);p.add_argument('--sanitize',choices=['address','thread'],default='address');p.add_argument('--python',default='/tmp/webtools397-peer/bin/python');p.add_argument('--report',type=Path,required=True);a=p.parse_args()
 env=os.environ.copy();env['PATH']='/opt/homebrew/opt/llvm@22/bin:'+env['PATH'];env['PYTHONDONTWRITEBYTECODE']='1'
 binary=Path(f'/tmp/webtools396-{a.sanitize}-{os.getpid()}');cert=SHARED/'surf/tests/http3/localhost.pem';key=SHARED/'http/v3/testdata/rsa2048.pem';peer=HERE/'http3_shutdown/peer.py'
 records=[h.run([a.odin,'build',HERE/'http3_shutdown',f'-collection:shared={SHARED}','-warnings-as-errors',f'-sanitize:{a.sanitize}',f'-out:{binary}'],env)]
 records+=h.exercise(binary,['server',cert,key],[lambda port:[binary,'client',port,cert]],env)
 records+=h.exercise(binary,['server',cert,key],[lambda port:[a.python,peer,'observe',port]],env)
 for mode in ['reject','wrong-id','increasing','trailing','decreasing','graceful']:
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
  server=subprocess.Popen([a.python,str(peer),mode,str(port),'--cert',str(cert),'--key',str(key)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
  lines=[];inbox=queue.Queue()
  def read_output():
   for line in server.stdout:lines.append(line.rstrip());inbox.put(line.rstrip())
  reader=threading.Thread(target=read_output,daemon=True);reader.start()
  try:
   line=inbox.get(timeout=5);assert line.startswith('READY'),line
   records.append(h.run([binary,mode,str(port),cert],env,20))
   expected='CLOSE 264' if mode in ('wrong-id','increasing') else 'CLOSE 262' if mode=='trailing' else 'CLOSE 256' if mode=='graceful' else None
   if expected:
    until=time.monotonic()+4
    while not any(expected in line for line in lines):
     remaining=until-time.monotonic();assert remaining>0,lines
     inbox.get(timeout=remaining)
  finally:
   server.terminate()
   try:server.wait(timeout=5)
   except subprocess.TimeoutExpired:server.kill();server.wait()
   reader.join(timeout=2);stdout="\n".join(lines[1:]);stderr=server.stderr.read();assert not stderr,stderr
   if mode=='reject':assert stdout.count('POST ONCE')==1,stdout
   if mode in ('wrong-id','increasing'):assert 'CLOSE 264' in stdout,stdout
   if mode=='trailing':assert 'CLOSE 262' in stdout,stdout
   if mode=='graceful':assert 'GOAWAY 0' in stdout and 'CLOSE 256' in stdout,stdout
   records.append(dict(mode=mode,stdout=stdout,stderr=stderr))
 result=dict(passed=True,sanitizer=a.sanitize,records=records);a.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
