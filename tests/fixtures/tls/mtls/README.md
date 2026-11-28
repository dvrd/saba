# mTLS fixtures

A test root and the identities it signs, for the suites that run Saba with
`client_auth = .Require`: `server.pem` (localhost and 127.0.0.1), `client.pem`
and `client-large.pem` (RSA 4096 with 120 names, so the client's Certificate
message spans several records). Valid for ten years from November 2026; the
root's key was not kept. Regenerate every file together with OpenSSL 3 or
later, from this directory, in bash:

```sh
days=3650
openssl req -x509 -newkey rsa:2048 -nodes -keyout root-key.pem -out root.pem -days $days -sha256 \
  -subj "/CN=Saba test root" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA root.pem -CAkey root-key.pem -CAcreateserial -out server.pem -days $days -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
openssl req -newkey rsa:2048 -nodes -keyout client-key.pem -out client.csr -subj "/CN=Saba test client"
openssl x509 -req -in client.csr -CA root.pem -CAkey root-key.pem -CAcreateserial -out client.pem -days $days -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n")
names=$(for i in $(seq 1 120); do printf "DNS:client-%03d.large.invalid," $i; done)
openssl req -newkey rsa:4096 -nodes -keyout client-large-key.pem -out client-large.csr -subj "/CN=Saba test client (large)"
openssl x509 -req -in client-large.csr -CA root.pem -CAkey root-key.pem -CAcreateserial -out client-large.pem -days $days -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=${names%,}\n")
rm -f *.csr root.srl root-key.pem
chmod 644 *.pem
```
