#!/bin/sh
# Fixed Host CLI dispatcher, never evals user input or accepts arbitrary commands.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN="$ROOT/target/release/dsh-mobile-iroh-host"
usage() { echo 'Usage: run-host.sh tls-prepare ABS_DATA_DIR | host ABS_DATA_DIR LOOPBACK_IP:PORT [--local-only]' >&2; exit 2; }
[ "$#" -ge 2 ] || usage
ACTION=$1
DATA_DIR=$2
case "$DATA_DIR" in /*) ;; *) echo 'Data directory must be absolute.' >&2; exit 2 ;; esac
[ -f "$BIN" ] && [ -x "$BIN" ] || { echo 'Build the native Host first.' >&2; exit 1; }
case "$ACTION" in
  tls-prepare)
    [ "$#" -eq 2 ] || usage
    exec "$BIN" tls-prepare --data-dir "$DATA_DIR"
    ;;
  host)
    [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
    TARGET=$3
    # The Rust CLI performs definitive IP loopback and nonzero-port validation.
    case "$TARGET" in 127.*:*) ;; '[::1]:'*) ;; *) echo 'Proxy target must be a loopback socket.' >&2; exit 2 ;; esac
    if [ "$#" -eq 4 ]; then
      [ "$4" = '--local-only' ] || usage
      exec "$BIN" host --data-dir "$DATA_DIR" --proxy-target "$TARGET" --local-only
    fi
    echo 'Starting experimental iroh relay/discovery endpoint; local startup is not proof of cross-network access.' >&2
    exec "$BIN" host --data-dir "$DATA_DIR" --proxy-target "$TARGET"
    ;;
  *) usage ;;
esac
