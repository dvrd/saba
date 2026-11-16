package saba_core

import credential_store "core:crypto/tls/credentials/store"
import credentials "core:crypto/tls/credentials"
import "core:testing"
import "core:mem"
import "core:log"
import "core:time"

// Synthetic credential fixtures from the owning Core credential test corpus.
HTTPS80_TEST_CERT :: `-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgICCAUwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAxMRc3lu
dGhldGljLmludmFsaWQwHhcNMjYwMTAxMDAwMDAwWhcNMzAwMTAxMDAwMDAwWjAc
MRowGAYDVQQDExFzeW50aGV0aWMuaW52YWxpZDCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBALzKDv1BF8mm3veTGtjYOwHY3aoGnB45q0TtnK+9tofBL/fw
xPcp5jyIMPwNwZzBzGGpU9WOUEJrnPDhUnsd+8gN8QI1Ch7tFnzPcBPN1r+IG72i
T5toZjtkRi6VCBN0paxawQo9nqjY1a8Zm7pWhmBCcFbqDGTPgjeM3Ag2tTFLVNoq
4faxKa0gd7SbiZIGG3gmSSzJiJjxVDg/zNDI223pD7zxEceF3oENFzX3mnPx3x0U
NmZJsn20CYJbJIN5WQyHBJcYtbZoSJNRXli2EhXFU5wGXHLLWqACWnrMZBfiZnGl
BdgacuIjdejWFp1EWiUBIsqYGIODYLpHeJqweucCAwEAAaNVMFMwDgYDVR0PAQH/
BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCwGA1UdEQQlMCOCEXN5bnRoZXRp
Yy5pbnZhbGlkgg5zZWNvbmQuaW52YWxpZDANBgkqhkiG9w0BAQsFAAOCAQEATtbz
yEECU4RXuFrNGw7BVhCrG2RcQlIJlECXTiE40K05kbAugB9INXG7sydBOECI5D62
qSUVWc2/CMdgDEZfXUOw6GY+qGmIsOPf46XVWehrX/bKhljdwm9sx7E7ZdGgCq7z
EbRTvSvuHLcTpTNRCKw/duGMQ1mRMTEeig1BE4VqNpYeCyj7ihBerg64Et58elf7
nbMI0vWMI5pOGXWTyStcMBPmq8ramXwF1EaE2e4fI7xwFQ5GTaBHB4ER4wP5l+oN
+OiG+BcmDpFQTQQYaxE0J7wQ4D+5mvO+5dC1EgwizOY5tZ8M8y0bIDVqmljUUY1B
4Nb7WoSH6sygdeLZmQ==
-----END CERTIFICATE-----
`
HTTPS80_TEST_KEY :: `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC8yg79QRfJpt73
kxrY2DsB2N2qBpweOatE7ZyvvbaHwS/38MT3KeY8iDD8DcGcwcxhqVPVjlBCa5zw
4VJ7HfvIDfECNQoe7RZ8z3ATzda/iBu9ok+baGY7ZEYulQgTdKWsWsEKPZ6o2NWv
GZu6VoZgQnBW6gxkz4I3jNwINrUxS1TaKuH2sSmtIHe0m4mSBht4JkksyYiY8VQ4
P8zQyNtt6Q+88RHHhd6BDRc195pz8d8dFDZmSbJ9tAmCWySDeVkMhwSXGLW2aEiT
UV5YthIVxVOcBlxyy1qgAlp6zGQX4mZxpQXYGnLiI3Xo1hadRFolASLKmBiDg2C6
R3iasHrnAgMBAAECggEACDy6vbMW4h4NUXkSLU71+CUpus7yBeGXRvklIofhDHhR
6vwO5Afoe1Cn7n99KKVOER7NwR4mA1flr57tNeD/iOGO1/1PdTz8A7MbXUnYal/6
ceJAnfPGriW4aDTpdsvapLQLAzLgFtbrL+oqoM1ArLeJZkltBAMH1/ul6BfW/REM
kv8+MwmH/xmERAzAYoFYiExmFkDfRTXlG8vtquMAuMAJGgC8R/6V4+lk4RvxspIY
1xXnMKl1pW7tpNNv/nSgC03d2Ao5df/0OVdR0psashQLgU1IzXh8zanCzEqDbqdw
1TZedgc1sIDEKp4kcK6gvMY6q0sKUdHR5F334v7jxQKBgQDEeiWQbNB6lpo4VDu0
iqf2pAEHLt2355L4A7NKROfOCHSPyvnYCxNI/BQ+lSu8sOyy8RKLCrVwuL1sIvkS
uN8D/FO+LXo6F86QfLF9wEQgSV02L0q80HU3dJ+XLa5CBgbtu6VMF3hT1IIgCL6y
hzGvQddjQ06btbHm1/3Uw3xEcwKBgQD1+62nozzZG9mbwvDqRKwpmv0/9sNB+xQd
S8cQMXy6hGh4x5b1oYMcqM1EA7Gbjk7FYSnMEt7Zb67aRboAEyczobAyDcJWiR8u
upZ2YR/d6EXGMfpTyFvumqk5M9fssnqEESnJkCO8VOWg9BKkEYBBNeNiu400Nfgt
XfsDabvGvQKBgHvNu/3Vk0irvWHhMf4BoPT5QuyTy4ImmaVOL5uM78QT797rt6M6
11wV+2uz82ti0MOwxE544Pu2bSXGo8v4Ug7g4KPlZC9W8QJ6kBz9GfB+Sg3qnt17
PWFES4unbTaNNbB3nSDlaRzpu1UULZWxOs2EX4Rc1Ruo0gDz+S4oQBWhAoGBAKFr
ko7C6YhT5V54893YSN5Yrj5Ocd4XpSCAfNZck0xW3bP8zkzMu5yQDXvHrMK3BWwz
kdkwvPsVdjoYrbGk4AHa5iRCsThWbZcdrOVsYRwfc8JXQ729as7OwaQfKGBU019d
X/280Caj07jm0mDGd1LTyS8egtAzZnRnCvU3aplFAoGAZ9GSBPAGbz7IWx1NQJ4q
nGuPeJ+5fOxR01b6SC+FY9bkWSYjLqs34C/dMgpa8X0/MoBc16DtbQHkKdG3zBNY
bOzudTyH/88plHy3wH2hEQdmqrdiuaoVggHrhWfWiKxJPsFZNkmXjP2JEwQGdc+2
KiRhi0U4QyOG4DSCNy8xI48=
-----END PRIVATE KEY-----
`

https80_make_store :: proc(t: ^testing.T) -> ^credential_store.Store {
	store, error := credential_store.create({}, context.allocator)
	assert(error.kind == .None)
	owner, created := credentials.create(transmute([]u8)string(HTTPS80_TEST_CERT), transmute([]u8)string(HTTPS80_TEST_KEY), {}, context.allocator)
	assert(created == .None)
	assert(credential_store.replace(store, &owner).kind == .None)
	testing.expect(t, owner == nil)
	return store
}

@(test)
https80_configuration_defaults_and_invalid_bounds_are_checked_before_startup :: proc(t: ^testing.T) {
	store := https80_make_store(t)
	defer credential_store.destroy(&store)
	context.logger = log.nil_logger()
	testing.expect(t, tls_config_valid(nil))
	valid := TLS_Config{store = store}
	testing.expect(t, tls_config_valid(&valid))
	samples := []TLS_Config{
		{}, {store = store, handshake_timeout = -time.Nanosecond},
		{store = store, close_timeout = -time.Nanosecond},
		{store = store, handshake_timeout = MAX_SERVER_TIMEOUT + time.Nanosecond},
		{store = store, close_timeout = MAX_SERVER_TIMEOUT + time.Nanosecond},
		{store = store, max_owned_bytes = 1023},
		{store = store, max_owned_bytes = 256*1024 + 1},
		{store = store, max_handshake_records = -1},
		{store = store, max_handshake_records = 65537},
	}
	for &config in samples {
		testing.expect(t, !tls_config_valid(&config))
		control: Server_Control
		testing.expect(t, !serve({tls = &config, control = &control,
			runtime_allocator = mem.panic_allocator()}))
		testing.expect(t, !control._in_use && !control._ever_published)
	}
}

@(test)
https80_empty_and_closed_credential_stores_are_invalid_without_consuming_them :: proc(t: ^testing.T) {
	empty, error := credential_store.create({}, context.allocator)
	assert(error.kind == .None)
	defer credential_store.destroy(&empty)
	config := TLS_Config{store = empty}
	testing.expect(t, !tls_config_valid(&config))
	owner, created := credentials.create(transmute([]u8)string(HTTPS80_TEST_CERT),
		transmute([]u8)string(HTTPS80_TEST_KEY), {}, context.allocator)
	assert(created == .None)
	assert(credential_store.replace(empty, &owner).kind == .None)
	testing.expect(t, tls_config_valid(&config))
	assert(credential_store.close(empty).kind == .None)
	testing.expect(t, !tls_config_valid(&config))
	view, viewed := credential_store.stats(empty)
	testing.expect_value(t, viewed.kind, .None)
	testing.expect(t, view.closed)
	testing.expect_value(t, view.active_leases, 0)
}
