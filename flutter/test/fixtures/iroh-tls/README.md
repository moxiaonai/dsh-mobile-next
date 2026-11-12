# TLS test fixtures

These files exist **only** for `test/iroh_tls_test.dart`, which binds an
in-process HTTPS server on `127.0.0.1` and verifies that the client pins a
private CA and retains the logical host / SAN during the handshake.

- `ca.pem` / `ca-key.pem` — a throwaway self-signed CA (`CN=Iroh Test CA`).
- `server.pem` / `server-key.pem` — a leaf issued by that CA for the test host.
- `server.csr`, `server.ext`, `ca.srl` — issuance byproducts kept for
  reproducibility.

## These are not secrets

The private keys are committed on purpose: the test must be reproducible on any
machine without a certificate-generation step. They protect nothing — the CA is
trusted by no system, is never installed anywhere, and only ever signs the
loopback server started inside the test process.

Do not reuse these certificates outside the test suite. Real deployment uses
the private CA generated per computer by `dsh-mobile-next/src/tls.ts`.

## Regenerating

```sh
cd flutter/test/fixtures/iroh-tls
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem \
  -days 3650 -subj "/CN=Iroh Test CA"
openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server.csr \
  -subj "/CN=iroh.test.localhost"
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out server.pem -days 3650 -extfile server.ext
```
