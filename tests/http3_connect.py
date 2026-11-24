#!/usr/bin/env python3
"""Native RFC9220 and independent pinned aioquic/wsproto loopback peers."""
import sys; sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import harness_env
import argparse,json,os,socket,subprocess,sys,importlib.util
from pathlib import Path
HERE=Path(__file__).resolve().parent;SHARED=Path(harness_env.shared())
spec=importlib.util.spec_from_file_location('h2_harness',HERE/'http2_connect.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
def main():
 p=argparse.ArgumentParser();p.add_argument('--odin',type=Path,default=Path(harness_env.odin()));p.add_argument('--sanitize',choices=['address','thread'],default=harness_env.sanitizer());p.add_argument('--python',default=None);p.add_argument('--mutual-tls',action='store_true');p.add_argument('--report',type=Path);a=p.parse_args();a.python=a.python or harness_env.aioquic_python()
 env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env.setdefault('ODIN_ROOT',str(harness_env.sdk()))
 binary=harness_env.workdir('saba-http3-connect-')/'server';cert=HERE / 'testdata/tls/localhost.pem';key=HERE / 'testdata/tls/rsa2048.pem';peer=HERE/'http3_connect/peer.py'
 records=[h.run([a.odin,'build',HERE/'http3_connect',f'-collection:shared={SHARED}','-warnings-as-errors',*harness_env.sanitize_for(a.sanitize),f'-out:{binary}'],env)]
 records+=h.exercise(binary,['server',cert,key],[lambda port:[binary,'client',port,cert],lambda port:[a.python,peer,'client',port]],env)
 with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 for mode in ['server','no-connect','invalid-setting']:
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
  server=subprocess.Popen([a.python,str(peer),mode,str(port),'--cert',str(cert),'--key',str(key)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
  try:
   line=server.stdout.readline();assert line.startswith('READY'),line
   records.append(h.run([binary,'client' if mode=='server' else 'negative',str(port),cert],env,30))
  finally:
   server.terminate()
   try:server.wait(timeout=5)
   except subprocess.TimeoutExpired:server.kill();server.wait()
   stdout=server.stdout.read();stderr=server.stderr.read();assert not stderr,stderr
   if mode=='server':assert 'RESET 268' in stdout,stdout
   records.append(dict(independent_server_stdout=stdout,independent_server_stderr=stderr))
 if a.mutual_tls:
  mtls=Path(env['ODIN_ROOT'])/'core/crypto/tls/testdata/mtls'
  records+=h.exercise(binary,['server-mtls',mtls/'server.pem',mtls/'server-key.pem',mtls/'root.pem'],[lambda port:[binary,'client-mtls',port,mtls/'root.pem',mtls/'client.pem',mtls/'client-key.pem',mtls/'client-large.pem',mtls/'client-large-key.pem']],env)
 result=dict(passed=True,sanitizer=a.sanitize,records=records);(a.report.write_text if a.report else (lambda text:None))(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
