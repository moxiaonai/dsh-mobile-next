# Native iroh source provenance

- Source: https://github.com/saya-ch/dsh-mobile-iroh
- Reviewed upstream commit: `b1d6ecdc5a22630e4edae07e44d2f0aa94a26fc9`.
- Vendored `host/src`, `host/tests` → `iroh-host`; `tether-core/src` → `iroh-core`; original Cargo lockfile and manifests retained (Host relative core path changes to `../iroh-core`). Cargo updates the lockfile solely for this three-member workspace.
- Compared both Rust source directories against https://github.com/saya-ch/dsh-mobile commit `4422eb7ca6bb47f468950d5f1996ad3b38b21fa0`, `native/iroh-host/src` and `native/iroh-core/src`: byte-identical before any Mac adaptations.
- Android transport crate is maintained separately by the Flutter integrator and shares package `dsh-mobile-iroh-core`, iroh 1.0.
- Original MIT, dsh-tether MIT, DSH Mobile Apache-2.0 licenses and upstream NOTICE are retained under `licenses/`. Original notices are not replaced; no upstream endorsement is claimed.

## Reviewed security contracts

- Host is an authenticated byte carrier, not an HTTP/TLS terminator or DSH authorization engine. The Gateway must terminate the opaque TLS and own application cookies, device tokens, Origin, CSRF and WebSocket route checks.
- v1 bounded NDJSON rejects unknown versions, duplicate/unknown fields, unexpected routes, invalid names and malformed pairing codes; QUIC authenticates EndpointIds and supplies transport replay protection.
- TLS preparation uses durable CA/identity and exact endpoint hostname `<first32>.<last32>.iroh.localhost`; metadata contains fixed material paths and public fingerprints, never PEM private key bytes.
- Native stdio permits only pairing-begin, device-list, device-forget and shutdown. TLS lease release is a separate bounded v1 record. No shell command interface is added.
- Existing private directories/files are verified, never chmod-repaired or silently regenerated. POSIX descriptor-relative nofollow operations check ownership, link count, private leaf modes, and untrusted writable ancestors. Mac uses O_SEARCH for ancestor directory handles. Any local change must preserve these checks.
- All performed endpoint tests use `--local-only` / Minimal preset and explicit loopback direct addresses. These are host-driven simulated topology checks, not real public direct/relay reachability or physical Android evidence.
