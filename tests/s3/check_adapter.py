#!/usr/bin/env python3
"""Verify legacy Saba S3 signatures/delegation with an isolated fake executor."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--odin',required=True)
args=parser.parse_args()
shared=Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='saba-s3-adapter-') as temporary:
    root=Path(temporary)
    packages=root/'shared'
    for name in ('aws',):
        shutil.copytree(shared/name,packages/name,ignore=shutil.ignore_patterns('.git','__pycache__','*_test.odin'))
    shutil.copytree(shared/'saba/s3',packages/'saba/s3',ignore=shutil.ignore_patterns('__pycache__'))
    (packages/'surf').mkdir()
    # Only the executor is substituted. AWS's real signer, file hashing,
    # provider protocol and Saba's real adapter all compile unchanged.
    (packages/'surf/fake.odin').write_text('''package surf
import "core:os"
import "core:strings"
Buffered_HTTP_Result :: struct {status:int,ok,transport_ok:bool,error:struct{code:int}}
calls:int
buffered_http_execute :: proc(method,url:string,body:[]u8,headers:[]string,ca_file:string,
 allow_http:bool=false,timeout_ms:i64=15000,upload_file:^os.File=nil,upload_size:i64=0)->([]u8,Buffered_HTTP_Result) {
 assert(!allow_http&&url=="https://examplebucket.s3.us-east-1.amazonaws.com/object")
 signed:=false
 for field in headers {if strings.has_prefix(field,"Authorization: AWS4-HMAC-SHA256 Credential=fixture-key/"){signed=true}}
 assert(signed)
 if method=="PUT" {
  if upload_file!=nil {data:[7]u8;n,e:=os.read(upload_file,data[:]);assert(e==nil&&n==7&&string(data[:])=="payload"&&upload_size==7&&timeout_ms==120000)}
  else {assert(string(body)=="payload"&&timeout_ms==15000)}
 } else {assert(method=="DELETE"&&len(body)==0&&upload_file==nil)}
 calls+=1
 return nil,{status=418,ok=false,transport_ok=true}
}
''')
    (root/'app').mkdir()
    (root/'app/main.odin').write_text('''package main
import s3 "shared:saba/s3"
import surf "shared:surf"
import "core:os"
import "core:time"
main :: proc() {
 put:proc(s3.S3_Config,s3.AWS_Credentials,string,[]u8,string)->s3.S3_Result=s3.s3_put
 file:proc(s3.S3_Config,s3.AWS_Credentials,string,string,string)->s3.S3_Result=s3.s3_put_file
 del:proc(s3.S3_Config,s3.AWS_Credentials,string)->s3.S3_Result=s3.s3_delete
 resolve:proc()->(s3.AWS_Credentials,bool)=s3.aws_credentials
 load:proc()->s3.S3_Config=s3.load_s3_config
 validate:proc(s3.S3_Config)->string=s3.s3_config_error
 presign:proc(s3.S3_Config,s3.AWS_Credentials,string,int,time.Time)->(string,bool)=s3.s3_download_url
 assert(resolve!=nil&&load!=nil&&validate!=nil&&presign!=nil)
 two_fields:=s3.S3_Result{418,false}
 config:=s3.S3_Config{bucket="examplebucket",region="us-east-1"}
 credentials:=s3.AWS_Credentials{"fixture-key","fixture-secret",""}
 assert(put(config,credentials,"object",transmute([]u8)string("payload"),"text/plain")==two_fields)
 assert(file(config,credentials,"object",os.args[1],"text/plain")==two_fields)
 assert(del(config,credentials,"object")==two_fields&&surf.calls==3)
}
''')
    body=root/'body';body.write_bytes(b'payload')
    binary=root/'fixture'
    subprocess.run([args.odin,'build',str(root/'app'),'-collection:shared='+str(packages),'-sanitize:address','-warnings-as-errors','-out:'+str(binary)],check=True)
    subprocess.run([str(binary),str(body)],check=True,timeout=5)
    real=root/'real-shared'
    for name in ('aws','surf','http','websocket'):
        shutil.copytree(shared/name,real/name,ignore=shutil.ignore_patterns('.git','__pycache__','*_test.odin'))
    shutil.copytree(shared/'saba/s3',real/'saba/s3',ignore=shutil.ignore_patterns('__pycache__'))
    (root/'real-app').mkdir()
    (root/'real-app/main.odin').write_text('''package main
import s3 "shared:saba/s3"
import "core:time"
main :: proc() {
 del:proc(s3.S3_Config,s3.AWS_Credentials,string)->s3.S3_Result=s3.s3_delete
 config:=s3.S3_Config{bucket="examplebucket",region="us-east-1"}
 assert(s3.s3_config_error(config)=="")
 assert(del(config,{},"object")==s3.S3_Result{})
 _,ok:=s3.s3_download_url(config,{"fixture-key","fixture-secret",""},"object",300,time.unix(1369353600,0))
 assert(ok)
}
''')
    real_binary=root/'real-fixture'
    subprocess.run([args.odin,'build',str(root/'real-app'),'-collection:shared='+str(real),'-sanitize:address','-warnings-as-errors','-out:'+str(real_binary)],check=True)
    subprocess.run([str(real_binary)],check=True,timeout=5)
print('Saba optional S3 adapter: exact legacy function types/two-field result and 3 real AWS delegations and real vendored dependency closure passed offline')
