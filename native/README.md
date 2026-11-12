# Native iroh transport (experimental)

本机启用步骤（中文）：[USAGE.md](USAGE.md)。

This workspace vendors the reviewed first-party Rust Host and shared core for an ARM64 Mac. Android transport is a separate workspace member owned by the mobile integrator. The Host forwards **opaque TLS** to an HTTPS Gateway listening on a nonzero loopback socket; it does not replace Gateway/application authorization.

## Build and tests

```sh
./native/scripts/build-macos.sh
./native/scripts/test-native.sh
```

Rust must already be installed. Scripts resolve the installed toolchain read-only, then place Cargo downloads/builds in this workspace (`native/.cargo-home`, `native/target`). They do not install toolchains or edit the DSH profile. The lockfile is required. First build can fetch pinned dependencies over the network. Default workspace members are Host/core; the test script also runs Android native host-driven tests.

Result: `native/target/release/dsh-mobile-iroh-host` (`aarch64-apple-darwin`). This is a local build, not a published official artifact.

## Controller/run contract

```sh
./native/scripts/run-host.sh tls-prepare /absolute/new-private-profile
./native/scripts/run-host.sh host /absolute/new-private-profile 127.0.0.1:3443 --local-only
```

Use a new private directory: native storage creates it with restricted permissions. If it exists, its owner/mode and ancestors must pass strict checks; **do not chmod a user's existing home/development/state directory to bypass a failure**. Existing corrupt/unreadable identities are never regenerated. Never store or log private key material, pairing codes or active QR records in evidence.

`tls-prepare --data-dir` emits one v1 JSON record with camelCase metadata: `endpointId`, `hostname`, `instanceId`, public CA/leaf fingerprints and validity timestamps in milliseconds, and `tls.caFile/certFile/keyFile` paths. Gateway loads those fixed files and terminates HTTPS. Use `--hold` and exact `{"version":1,"type":"tls-release"}` line when the controller must retain the TLS lease until Gateway certificate installation.

`host --data-dir --proxy-target` requires a literal loopback socket with a nonzero port. Native stdio is v1 bounded NDJSON; events use snake_case. `ready` provides `endpoint_id`, `direct_addresses`, `local_only`; pairing/device events are separate. Commands are exclusively `pairing-begin`, `device-list`, `device-forget` (canonical EndpointId in `id`) and `shutdown`. Parent EOF or exact shutdown emits `stopped` and releases owned connections/tasks. Unknown commands/fields fail closed without echoing submitted secrets.

The dispatcher script accepts only those fixed preparation/start operations with quoted argument vectors, never arbitrary shell commands. Without `--local-only`, Host starts real iroh discovery/relay services; that mode requires an explicit operator action. **The verification here does not start public endpoints**.

## Evidence and limitations

See [provenance/security review](<PROVENANCE.md>) and [Mac build/test evidence](<evidence/MAC_ARM64.md>). Native loopback tests exercise authenticated QUIC, exact raw-byte forwarding, pairing persistence/revocation, quotas, bounded messages, subprocess ownership and TLS transaction/lease checks. Host-driven Android Rust tests do not prove JNI runtime/physical-device behavior, packaged Flutter WebView behavior, or cellular/public direct/relay access.

Retained upstream notices/licenses: [NOTICE](<licenses/NOTICE>), [MIT](<licenses/LICENSE>), [dsh-tether MIT](<licenses/LICENSE.dsh-tether>), [DSH Mobile Apache-2.0](<licenses/LICENSE.dsh-mobile>).
