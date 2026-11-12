# Flutter Android iroh transport

Real iroh QUIC carrier, not an HTTP gateway shim. This crate retains the upstream
`AndroidTransportSession`, long-lived authenticated control stream and owned raw
TCP loopback/CONNECT listeners. Every raw TCP connection opens a `proxy` bi-stream;
TLS bytes are forwarded unchanged. ALPN: `dsh-mobile-iroh/0`, wire version 1.
First connection sends `pair` with six-digit code; reconnect sends `hello` using
the same persisted private endpoint identity. Gateway pairing/renew remains a
separate end-to-end HTTPS operation using the existing Mobile device token.

## Provenance / licensing

Rust source copied from saya-ch/dsh-mobile native/iroh-android-transport commit
`4422eb7ca6bb47f468950d5f1996ad3b38b21fa0` (2026-11-12 checkout).
This transport declares MIT; retain LICENSE (Copyright 2026 Guangqi Zhang) and
LICENSE.apache for the main repository. The only modification to upstream Rust
is JNI symbols renamed for the existing Flutter package `com.example.dsh_mobile`.
No Android application ID, signature, keystore or SDK installation is changed.
Reference standalone implementation: saya-ch/dsh-mobile-iroh commit
`b1d6ecdc5a22630e4edae07e44d2f0aa94a26fc9`.

## Build (existing SDK/NDK required)

The workspace Cargo.lock must exist. Install the Rust target separately in an
authorized toolchain environment; the script deliberately does not install it:

```sh
rustup target add aarch64-linux-android x86_64-linux-android
export ANDROID_NDK_HOME=/path/to/existing/android-sdk/ndk/28.2.13676358
bash native/iroh-android/build-android.sh arm64-v8a
bash native/iroh-android/build-android.sh x86_64
cd flutter
flutter build apk --debug
```

The existing local SDK is configured by flutter/android/local.properties. Build
script uses API 24 and 16-KB ELF page alignment, and writes libraries to Android's
standard app/src/main/jniLibs ABI directories. No binary is bundled in source
unless this build completes. Missing native library fails with native_unavailable;
it does not silently use LAN, Cloudflare, plaintext or a fake HTTP fallback.
Relay TLS requires the pinned rustls-platform-verifier JVM artifact (0.2.0 from
Cargo.lock) declared by the Flutter Android Gradle build. JNI methods and verifier
classes need preservation if a future release enables shrinking.

## Trust / lifecycle

QR v1 contains canonical base64 DER CA. Dart HttpClient trusts only that CA;
connectionFactory explicitly wraps raw loopback TCP in SecureSocket.secure with
the logical HTTPS host for SNI/SAN verification and QR-only SecurityContext.
HttpClient custom DIRECT connectionFactory does NOT wrap TLS automatically.
HTTP request/cookie authority remains the original HTTPS origin.
WebSocket uses the same HttpClient. Android WebView resolves *.localhost to the
stable localPort; its actual server certificate is verified by Android PKIX
using ONLY the active QR CA, checking root self-signature/CA/validity and exact
DNS SAN/serverAuth usage. Issuer-name matching is never used for iroh. Chromium
loopback behavior and this challenge path still require actual Android testing.

Cancellation increments Dart generation before shutdown; JNI monotonic owners
reject late connect publication or old close calls. Native teardown closes the
QUIC endpoint, listener and children before a new owner's fixed-port lease.
DshConnection disposal releases its carrier. Credential JSON stores optional
transport metadata but never irohCode/gatewayToken or sessionToken. Existing
LAN records without transport remain readable. The existing credential store is
still plaintext App-private JSON, not Android Keystore; this task did not migrate it.

## Verification boundaries

Run `cargo test --release --manifest-path native/Cargo.toml -p dsh-mobile-iroh-android-transport`
for upstream real-QUIC byte/proxy/ownership tests on a host. That is not Android
runtime or physical-device evidence. Flutter tests: pairing_flow_test.dart and
iroh_pairing_test.dart.
No service is deployed and no public tunnel is opened by these build/test steps.
