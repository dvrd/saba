package server

import core "core"
import "core:crypto/tls"

TLS_Client_Auth_Config :: tls.Client_Auth_Config
TLS_Client_Auth_Mode :: tls.Client_Auth_Mode
TLS_Peer_Identity :: tls.Peer_Identity

// The facade borrows the normal authenticated connection during its handler.
// Copying this value retains no handshake certificates or request storage.
tls_peer_identity :: proc(connection:^Connection)->TLS_Peer_Identity {
 if connection==nil||connection._transport==nil {return {}}
 return core.tls_peer_identity(connection._transport)
}
