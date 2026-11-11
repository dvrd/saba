// Independent RFC8441 and RFC6455 wire peer using only the Go standard library.
package main

import (
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

type frame struct {
	kind, flags byte
	id          uint32
	data        []byte
}

func write(c net.Conn, kind, flags byte, id uint32, data []byte) error {
	h := make([]byte, 9)
	h[0] = byte(len(data) >> 16)
	h[1] = byte(len(data) >> 8)
	h[2] = byte(len(data))
	h[3] = kind
	h[4] = flags
	binary.BigEndian.PutUint32(h[5:], id)
	if _, e := c.Write(h); e != nil {
		return e
	}
	_, e := c.Write(data)
	return e
}
func read(c net.Conn) (frame, error) {
	h := make([]byte, 9)
	if _, e := io.ReadFull(c, h); e != nil {
		return frame{}, e
	}
	n := int(h[0])<<16 | int(h[1])<<8 | int(h[2])
	if n > 1<<16 {
		return frame{}, fmt.Errorf("oversize frame")
	}
	f := frame{kind: h[3], flags: h[4], id: binary.BigEndian.Uint32(h[5:]) & 0x7fffffff, data: make([]byte, n)}
	_, e := io.ReadFull(c, f.data)
	return f, e
}
func lit(dst []byte, name, value string) []byte {
	return append(append(append(append(dst, 0, byte(len(name))), []byte(name)...), byte(len(value))), []byte(value)...)
}
func indexed(dst []byte, index byte, value string) []byte {
	return append(append(dst, index, byte(len(value))), []byte(value)...)
}
func connect(path string) []byte {
	b := indexed(nil, 2, "CONNECT")
	b = lit(b, ":protocol", "websocket")
	b = append(b, 0x87)
	b = indexed(b, 1, "synthetic.invalid")
	b = indexed(b, 4, path)
	b = lit(b, "sec-websocket-version", "13")
	b = lit(b, "sec-websocket-protocol", "chat.v2")
	return lit(b, "origin", "https://allowed.invalid")
}
func masked(op byte, data []byte) []byte {
	if len(data) > 125 {
		panic("short fixture only")
	}
	out := []byte{0x80 | op, 0x80 | byte(len(data)), 1, 2, 3, 4}
	for i, v := range data {
		out = append(out, v^out[2+i%4])
	}
	return out
}
var settingsAcks,pingAcks,frames int
func advance(c net.Conn, f frame) error {
 frames++
	if f.kind == 4 && f.flags&1 == 0 {
 settingsAcks++
		return write(c, 4, 1, 0, nil)
	}
	if f.kind == 6 && f.flags&1 == 0 {
 pingAcks++
		return write(c, 6, 1, 0, f.data)
	}
	if f.kind == 0 && len(f.data) > 0 {
		v := make([]byte, 4)
		binary.BigEndian.PutUint32(v, uint32(len(f.data)))
		if e := write(c, 8, 0, f.id, v); e != nil {
			return e
		}
		return write(c, 8, 0, 0, v)
	}
	return nil
}
func until(c net.Conn, id uint32, kind byte) (frame, error) {
	for i := 0; i < 4096; i++ {
		f, e := read(c)
		if e != nil {
			return f, e
		}
		if e = advance(c, f); e != nil {
			return f, e
		}
		if f.kind == 3 {
			return f, fmt.Errorf("unexpected RST stream%d: %x", f.id, f.data)
		}
		if f.id == id && f.kind == kind {
			return f, nil
		}
	}
	return frame{}, fmt.Errorf("no frame")
}
func data(c net.Conn, id uint32, want []byte) error {
	got := []byte{}
	for len(got) < len(want) {
		f, e := until(c, id, 0)
		if e != nil {
			return e
		}
		got = append(got, f.data...)
	}
	if string(got) != string(want) {
		return fmt.Errorf("DATA mismatch got%x want%x", got, want)
	}
	return nil
}

// The peer advertises a zero response HPACK table. Decode bounded literal
// lengths and static indices independently; Huffman strings need only skipping.
func hpint(b []byte, at *int, bits uint) (uint64,error) {
 if *at>=len(b) {return 0,io.ErrUnexpectedEOF};mask:=byte((1<<bits)-1);n:=uint64(b[*at]&mask);*at++
 if n<uint64(mask) {return n,nil};shift:=uint(0)
 for {if *at>=len(b)||shift>56 {return 0,fmt.Errorf("HPACK integer")};v:=b[*at];*at++;n+=uint64(v&127)<<shift;if v&128==0 {return n,nil};shift+=7}
}
func hpstring(b []byte,at *int)(string,bool,error) {
 if *at>=len(b) {return "",false,io.ErrUnexpectedEOF};huffman:=b[*at]&128!=0;n,e:=hpint(b,at,7);if e!=nil||n>uint64(len(b)-*at) {return "",false,fmt.Errorf("HPACK string")};value:=string(b[*at:*at+int(n)]);*at+=int(n);return value,huffman,nil
}
func conditionalHeadFields(b []byte)(bool,bool,error) {
 length,notModified:=false,false
 for at:=0;at<len(b); {
  first:=b[at]
  if first&128!=0 {index,e:=hpint(b,&at,7);if e!=nil{return false,false,e};length=length||index==28;notModified=notModified||index==11;continue}
  if first&0xe0==0x20 {_,e:=hpint(b,&at,5);if e!=nil{return false,false,e};continue}
  bits:=uint(4);if first&0x40!=0 {bits=6};index,e:=hpint(b,&at,bits);if e!=nil{return false,false,e}
  name:="";if index==0 {value,huffman,e:=hpstring(b,&at);if e!=nil{return false,false,e};if !huffman {name=value}}
  _,_,e=hpstring(b,&at);if e!=nil{return false,false,e}
  length=length||index==28||name=="content-length"
 }
 return length,notModified,nil
}
func request(path string) []byte {
 b:=[]byte{0x82,0x87};b=indexed(b,1,"synthetic.invalid");return indexed(b,4,path)
}
func check(e error) {if e!=nil {panic(e)}}
func main() {
 start:=time.Now();defer func(){fmt.Println("elapsed",time.Since(start),"acks",settingsAcks,pingAcks,"frames",frames)}()
 c,e:=tls.Dial("tcp",os.Args[1],&tls.Config{InsecureSkipVerify:true,ServerName:"localhost",NextProtos:[]string{"h2"}});check(e);defer c.Close()
 check(c.SetDeadline(time.Now().Add(15*time.Second)))
 _,e=c.Write([]byte("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"));check(e)
 check(write(c,4,0,0,[]byte{0,2,0,0,0,0,0,1,0,0,0,0}))
 settings,e:=until(c,0,4);check(e);grant:=uint32(0)
 for at:=0;at+6<=len(settings.data);at+=6 {if binary.BigEndian.Uint16(settings.data[at:])==3 {grant=binary.BigEndian.Uint32(settings.data[at+2:])}}
 if grant!=32 {panic(fmt.Sprintf("grant %d want32",grant))}
 if len(os.Args)>2 && os.Args[2]=="drain" {
  check(write(c,1,4,1,connect("/socket")));_,e:=until(c,1,1);check(e)
  check(write(c,1,5,3,request("/drain")))
  closed,final:=false,false
  for !closed || !final {f,e:=read(c);check(e);check(advance(c,f));if f.kind==0 && f.id==1 && len(f.data)>0 {if len(f.data)!=4 || f.data[0]!=0x88 || binary.BigEndian.Uint16(f.data[2:])!=1001 {panic("drain WS close1001 missing")};closed=true;check(write(c,0,1,1,masked(8,[]byte{3,233})))};if f.kind==7 && binary.BigEndian.Uint32(f.data[:4])!=0x7fffffff {final=true}}
  fmt.Println("PASS global drain final-goaway websocket-close1001");return
 }
 // Twenty live continuations plus a parked producer, incomplete POST and WS.
 for id:=uint32(1);id<=39;id+=2 {check(write(c,1,5,id,request("/hold")))}
 check(write(c,1,5,41,request("/stream")))
 post:=indexed([]byte{0x83,0x87},1,"synthetic.invalid");post=indexed(post,4,"/post");post=lit(post,"content-length","4")
 check(write(c,1,4,43,post));check(write(c,0,0,43,[]byte("ab")))
 check(write(c,1,4,45,connect("/socket")))
 // Fast ordinary requests finish while those twenty-three streams are idle.
 check(write(c,1,5,47,request("/health")));check(data(c,47,[]byte("http-ok")))
 fmt.Println("first",time.Since(start))
 // Cancellation belongs only to one continuation and one producer.
 reset:=[]byte{0,0,0,8};check(write(c,3,0,1,reset));check(write(c,3,0,41,reset))
 // More than32 lifetime IDs on this same connection, with grace PING replies.
 for id:=uint32(49);id<=177;id+=2 {check(write(c,1,5,id,request("/health")));check(data(c,id,[]byte("http-ok")))}
 fmt.Println("65",time.Since(start))
 check(write(c,0,1,43,[]byte("cd")));check(data(c,43,[]byte("http-ok")))
 check(write(c,0,0,45,masked(1,[]byte("still-live"))));check(data(c,45,append([]byte{0x81,10},[]byte("still-live")...)))
 fmt.Println("ws",time.Since(start))
 check(write(c,1,5,179,request("/release")))
 remaining:=map[uint32]bool{};for id:=uint32(3);id<=39;id+=2 {remaining[id]=true};remaining[179]=true
 bodies:=map[uint32][]byte{}
 for len(remaining)>0 {f,e:=read(c);check(e);check(advance(c,f));if f.kind==3 {panic(fmt.Sprintf("unexpected reset %d",f.id))};if f.kind==0 {bodies[f.id]=append(bodies[f.id],f.data...);if f.flags&1!=0 && remaining[f.id] {want:="held-ok";if f.id==179 {want="http-ok"};if string(bodies[f.id])!=want {panic(fmt.Sprintf("body %d %q",f.id,bodies[f.id]))};delete(remaining,f.id)}}}
 // A completed response producer uses the same ordinary scheduling path.
 check(write(c,1,5,181,request("/stream")));check(data(c,181,[]byte("held-ok")))
 // Leave this producer's stream window exhausted, replenishing connection
 // credit only. Another ordinary response must still finish independently.
 check(write(c,1,5,183,request("/bulk")))
 check(write(c,1,5,185,request("/health")))
 bulk,fast:=0,[]byte{}
 for string(fast)!="http-ok" {
  f,e:=read(c);check(e)
  if f.kind==3 {panic(fmt.Sprintf("bulk reset %d",f.id))}
  if f.kind==0 && f.id==183 {
   bulk+=len(f.data);credit:=make([]byte,4);binary.BigEndian.PutUint32(credit,uint32(len(f.data)));if len(f.data)>0 {check(write(c,8,0,0,credit))}
  } else {check(advance(c,f));if f.kind==0 && f.id==185 {fast=append(fast,f.data...)}}
 }
 if bulk>65535 {panic("stream window was exceeded")}
 check(write(c,3,0,183,reset))
 // Rejected operation allocation is local503, then this lane remains usable.
 check(write(c,1,5,187,request("/no-content")))
 ended:=false
 for !ended {f,e:=read(c);check(e);check(advance(c,f));if f.kind==3 {panic(fmt.Sprintf("no-content reset%d",f.id))};if f.id==187 && f.kind==0 {if len(f.data)!=0 {panic("204 body")};ended=f.flags&1!=0}}
 check(write(c,1,5,189,request("/pressure")))
 head,e:=until(c,189,1);check(e)
 if len(head.data)==0 || head.data[0]==0x88 {panic(fmt.Sprintf("pressure did not reject: %x",head.data))}
 check(write(c,1,5,191,request("/health")));check(data(c,191,[]byte("http-ok")))
 // A real conditional asset has a nonempty GET representation but an
 // empty HEAD304 body. The framework must not invent Content-Length0.
 check(write(c,1,5,193,request("/asset")));check(data(c,193,[]byte("asset-body")))
 conditional:=indexed(nil,2,"HEAD");conditional=append(conditional,0x87);conditional=indexed(conditional,1,"synthetic.invalid");conditional=indexed(conditional,4,"/asset");conditional=lit(conditional,"if-none-match","*")
 check(write(c,1,5,195,conditional));head,e=until(c,195,1);check(e)
 hasLength,notModified,e:=conditionalHeadFields(head.data);check(e)
 if !notModified||hasLength {panic(fmt.Sprintf("conditional HEAD304: not-modified=%v content-length=%v wire=%x",notModified,hasLength,head.data))}
 ended=head.flags&1!=0
 for !ended {head,e=read(c);check(e);check(advance(c,head));if head.kind==3 {panic("HEAD304 reset")};if head.id!=195 {continue};if head.kind==0&&len(head.data)>0 {panic("HEAD304 body")};ended=head.flags&1!=0}
 // Six admitted WebSockets prove upgrades use the same configured grant,
 // without a separate hard4 context ceiling.
 sockets:=[]uint32{45,197,199,201,203,205}
 for _,id:=range sockets[1:] {check(write(c,1,4,id,connect("/socket")));head,e:=until(c,id,1);check(e);if head.flags&1!=0 {panic("sixth WebSocket rejected")}}
 // GOAWAY closes admission while admitted WebSockets remain usable.
 check(write(c,7,0,0,make([]byte,8)))
 final:=false
 for !final {f,e:=read(c);check(e);check(advance(c,f));if f.kind==7 {if len(f.data)<8 {panic("shortGOAWAY")};last:=binary.BigEndian.Uint32(f.data[:4]);code:=binary.BigEndian.Uint32(f.data[4:8]);if code!=0 {panic("errorGOAWAY")};if last!=0x7fffffff {if last<205 {panic("admitted request excluded")};final=true}}}
 for _,id:=range sockets {
  check(write(c,0,0,id,masked(1,[]byte("drain-live"))));check(data(c,id,append([]byte{0x81,10},[]byte("drain-live")...)))
  check(write(c,0,1,id,masked(8,[]byte{3,232})))
  for {f,e:=read(c);check(e);check(advance(c,f));if f.kind==0 && f.id==id && f.flags&1!=0 {break}}
 }
 fmt.Println("PASS grant32 live23 ordinary65 cancellation3 blocked-window local503 no-content conditional-head304 goaway websocket6-progress")
}
