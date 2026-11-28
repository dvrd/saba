// Keeping a test's descriptors out of the programs other tests start.
//
// A forked program inherits every descriptor of the test binary that is not
// close-on-exec. Sockets from core:net are not on Darwin, and a pipe or a
// socket made with posix is marked only after it exists. A program started by
// one test would then hold a connection of another test running in parallel:
// that test's close or reset would not reach the server until the program
// exits, and the program's own socket count would include it. So every
// descriptor the support packages create is made under this lock and marked
// close-on-exec before it is released, and every program is forked under it.
package saba_test_harness

import "core:net"
import "core:sync"
import "core:sys/posix"
import "core:time"

descriptors: sync.Mutex

// Marks fd close-on-exec. The caller holds descriptors.
close_on_exec :: proc(fd: posix.FD) {
	_ = posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
}

// A socket made like posix.socket, close-on-exec, or -1.
socket :: proc(domain: posix.AF, type: posix.Sock, protocol := posix.Protocol(0)) -> posix.FD {
	sync.guard(&descriptors)
	fd := posix.socket(domain, type, protocol)
	if fd >= 0 {
		close_on_exec(fd)
	}
	return fd
}

// A blocking TCP connection to 127.0.0.1:port, close-on-exec, with
// TCP_NODELAY and reads and writes that give up after timeout. Only the
// socket is made under descriptors: the connect may wait, and the lock must
// not hold up other tests.
dial_loopback :: proc(port: int, timeout: time.Duration) -> (net.TCP_Socket, net.Network_Error) {
	fd := socket(.INET, .STREAM, .TCP)
	if fd < 0 {
		return {}, net.Create_Socket_Error.Insufficient_Resources
	}
	address := posix.sockaddr_in {
		sin_family = .INET,
		sin_port   = u16be(u16(port)),
		sin_addr   = {s_addr = transmute(posix.in_addr_t)u32be(0x7f000001)},
	}
	when ODIN_OS == .Darwin {
		address.sin_len = size_of(address)
	}
	if posix.connect(fd, cast(^posix.sockaddr)&address, size_of(address)) != .OK {
		error := dial_error(posix.errno())
		posix.close(fd)
		return {}, error
	}
	socket := net.TCP_Socket(fd)
	_ = net.set_option(socket, .TCP_Nodelay, true)
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	_ = net.set_option(socket, .Send_Timeout, timeout)
	return socket, nil
}

@(private)
dial_error :: proc(errno: posix.Errno) -> net.Dial_Error {
	#partial switch errno {
	case .ECONNREFUSED:
		return .Refused
	case .ECONNRESET:
		return .Reset
	case .ETIMEDOUT:
		return .Timeout
	case .EINTR:
		return .Interrupted
	case .ENETDOWN, .ENETUNREACH:
		return .Network_Unreachable
	case .EHOSTUNREACH:
		return .Host_Unreachable
	case .EADDRINUSE, .EADDRNOTAVAIL:
		return .Address_In_Use
	case .ENOBUFS:
		return .Insufficient_Resources
	}
	return .Unknown
}
