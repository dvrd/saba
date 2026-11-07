#!/usr/bin/env python3
"""Darwin asset strategy microbenchmark; synthetic owned files, warm filesystem cache.

The preload path uses the production bounded cache. The manifest and on-demand
paths are diagnostic prototypes, not additional supported server modes. No HTTP
transport, concurrency, cold-cache or deployment-performance claim is made.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--odin',required=True,type=Path)
parser.add_argument('--report',required=True,type=Path)
parser.add_argument('--repetitions',type=int,default=3)
args=parser.parse_args()
if platform.system()!='Darwin':
    raise SystemExit('This diagnostic currently measures Darwin ru_maxrss bytes only.')
if args.repetitions<3:
    raise SystemExit('At least three repetitions are required.')
args.report.parent.mkdir(parents=True,exist_ok=True)
report={'platform':platform.platform(),'clock':'monotonic ns','repetitions':args.repetitions,
        'limits':'warm cache; file lookup/read only, no HTTP/concurrency/cold disk',
        'manifest_policy':'SHA256 fingerprint prepared at build time; verify full body on every diagnostic read',
        'compiler':subprocess.check_output([str(args.odin),'version'],text=True).strip(),
        'cases':[],'rows':[]}
with tempfile.TemporaryDirectory(prefix='asset-strategies-',dir=args.report.parent) as temporary:
    temporary=Path(temporary)
    binary=temporary/'benchmark'
    source=Path(__file__).resolve().parent/'testdata/benchmark'
    subprocess.run([str(args.odin),'build',str(source),'-o:speed','-warnings-as-errors','-out:'+str(binary)],check=True)
    for count,size in [(32,1024),(256,16*1024),(512,64*1024)]:
        directory=temporary/f'{count}-{size}'
        directory.mkdir()
        body=bytes(range(256))*(size//256)
        digest=hashlib.sha256(body).hexdigest()
        names=[f'{index:04d}.bin' for index in range(count)]
        for name in names:(directory/name).write_bytes(body)
        began=time.monotonic_ns()
        # Emulate build fingerprinting from the on-disk content, not just the
        # already computed generation digest. Build work stays outside startup.
        manifest=''.join(name+'\t'+hashlib.sha256((directory/name).read_bytes()).hexdigest()+'\n' for name in names)
        Path(str(directory)+'.manifest').write_text(manifest)
        report['cases'].append({'files':count,'file_bytes':size,'total_body_bytes':count*size,
                                'manifest_build_ns':time.monotonic_ns()-began})
        for repetition in range(args.repetitions):
            # Rotate order to reduce systematic effects from whichever runs first.
            modes=['preload','manifest','on_demand']
            modes=modes[repetition%3:]+modes[:repetition%3]
            for mode in modes:
                completed=subprocess.run([str(binary),mode,str(directory),str(count),'1001'],
                                         capture_output=True,text=True,check=True,timeout=60)
                row=json.loads(completed.stdout)
                row.update(repetition=repetition,file_bytes=size,total_body_bytes=count*size)
                report['rows'].append(row)
                args.report.write_text(json.dumps(report,indent=2)+'\n')
print(f'{len(report["rows"])} measured cells saved to {args.report}')
