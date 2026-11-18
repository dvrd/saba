#!/usr/bin/env python3
"""Owned independent negotiated QUIC idle-timeout qualification."""
import argparse, hashlib, json, os, platform, subprocess, time
from pathlib import Path
HERE=Path(__file__).resolve().parent
SHARED=HERE.parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def manifest(paths):
    files=[p for root in paths for p in ([root] if root.is_file() else sorted(root.rglob('*'))) if p.is_file() and p.suffix in ('.odin','.py','.pem','.c','.h','.s','.S','.so','.dylib') and '.git' not in p.parts and '__pycache__' not in p.parts]
    return {str(p):sha(p) for p in files}
def main():
    p=argparse.ArgumentParser();p.add_argument('--odin',type=Path,required=True);p.add_argument('--python',default='/tmp/webtools397-peer/bin/python');p.add_argument('--sanitize',choices=['address','thread'],default='address');p.add_argument('--report',type=Path,required=True);p.add_argument('--cases',nargs='*',default=['client-pool','client-authenticated','server-idle','server-authenticated','server-forged','saba-idle','server-request-budget']);a=p.parse_args()
    env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env['PATH']='/opt/homebrew/opt/llvm@22/bin:'+env.get('PATH','')
    binary=Path(f'/tmp/webtools401-{a.sanitize}-{os.getpid()}');records=[]
    roots=[SHARED/'http',SHARED/'surf',SHARED/'async',SHARED/'saba/core',Path(env['ODIN_ROOT'])/'core',Path(env['ODIN_ROOT'])/'base',HERE/'http3_idle',Path(__file__).resolve()]
    before=manifest(roots);report={'platform':platform.platform(),'architecture':platform.machine(),'odin_root':env['ODIN_ROOT'],'sanitizer':a.sanitize,'compiler_sha256':sha(a.odin),'source_before':before,'records':records}
    def run(command,timeout=120):
        start=time.monotonic();r=subprocess.run(list(map(str,command)),env=env,capture_output=True,text=True,timeout=timeout)
        rec={'command':list(map(str,command)),'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'seconds':time.monotonic()-start};records.append(rec)
        assert r.returncode==0,rec
        assert 'ERROR: AddressSanitizer' not in r.stderr and 'WARNING: ThreadSanitizer' not in r.stderr,rec
        return r.stdout
    try:
        report['compiler_version']=run([a.odin,'version']).strip()
        peer_root=Path(run([a.python,'-c','import aioquic,pathlib;print(pathlib.Path(aioquic.__file__).parent)']).strip())
        peer_before=manifest([peer_root]);report['peer_before']=peer_before
        run([a.odin,'build',HERE/'http3_idle',f'-collection:shared={SHARED}','-warnings-as-errors','-vet',f'-sanitize:{a.sanitize}',f'-out:{binary}'])
        report['binary_sha256']=sha(binary)
        for case in a.cases:
            run([a.python,HERE/'http3_idle/peer.py',case,'--binary',binary,'--cert',HERE / 'testdata/tls/localhost.pem','--key',HERE / 'testdata/tls/rsa2048.pem'],40)
        report['peer_after']=manifest([peer_root]);assert peer_before==report['peer_after'],'published peer sources changed'
        report['passed']=True
    finally:
        report['source_after']=manifest(roots);report['source_unchanged']=before==report['source_after'];report['passed']=report.get('passed',False) and report['source_unchanged'];a.report.write_text(json.dumps(report,indent=2)+'\n')
    assert report['source_unchanged'],'source changed during qualification; refresh the source-bound run'
if __name__=='__main__':main()
