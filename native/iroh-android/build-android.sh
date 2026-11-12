#!/usr/bin/env bash
# Build only: never deploy, change Android signer, start a host or install SDKs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your existing NDK directory}"
ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) TARGET=aarch64-linux-android; CLANG_TARGET=aarch64-linux-android24 ;;
  x86_64) TARGET=x86_64-linux-android; CLANG_TARGET=x86_64-linux-android24 ;;
  *) echo 'Supported ABI: arm64-v8a or x86_64' >&2; exit 2 ;;
esac
case "$(uname -s)" in
  Darwin) HOST=darwin-x86_64 ;;
  Linux) HOST=linux-x86_64 ;;
  *) echo 'Run the explicit cargo/NDK recipe on this host' >&2; exit 2 ;;
esac
BIN="${ANDROID_NDK_HOME:?}/toolchains/llvm/prebuilt/$HOST/bin"
test -x "$BIN/${CLANG_TARGET}-clang"
KEY="${TARGET//-/_}"
UPPER="$(printf '%s' "$KEY" | tr '[:lower:]' '[:upper:]')"
export "CARGO_TARGET_${UPPER}_LINKER=$BIN/${CLANG_TARGET}-clang"
export "CC_${KEY}=$BIN/${CLANG_TARGET}-clang"
export "AR_${KEY}=$BIN/llvm-ar"
export "CARGO_TARGET_${UPPER}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
export CARGO_TARGET_DIR="$ROOT/native/target"
cargo build --locked --release --manifest-path "$ROOT/native/Cargo.toml" -p dsh-mobile-iroh-android-transport --target "$TARGET"
OUTPUT="$ROOT/flutter/android/app/src/main/jniLibs/$ABI"
mkdir -p "$OUTPUT"
cp "$ROOT/native/target/$TARGET/release/libdsh_mobile_iroh_android_transport.so" "$OUTPUT/"
"$BIN/llvm-nm" --dynamic --defined-only "$OUTPUT/libdsh_mobile_iroh_android_transport.so"
