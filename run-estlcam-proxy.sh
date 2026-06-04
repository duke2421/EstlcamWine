#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  run-estlcam-proxy.sh [options]

Options:
  --wineprefix PATH       Wine prefix containing Estlcam
  --estlcam-path PATH     Windows path to Estlcam.exe
  --device PATH           Linux serial device, default: /dev/ttyUSB0
  --com-port COMx         Wine COM port to expose, default: COM4
  --baud RATE             Initial baud rate, default: 115200
  --log PATH              Proxy log path, default: ./serial-proxy.log
  --no-settings-update    Do not edit Estlcam's Settings CNC file
  -h, --help              Show this help

Environment variables with the same names are also supported:
  WINEPREFIX, ESTLCAM_PATH, SERIAL_DEVICE, COM_PORT, INITIAL_BAUD, PROXY_LOG
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="${WINEPREFIX:-$HOME/.wine-estlcam}"
ESTLCAM_PATH="${ESTLCAM_PATH:-C:\\Program Files (x86)\\Estlcam11\\Estlcam.exe}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyUSB0}"
COM_PORT="${COM_PORT:-COM4}"
INITIAL_BAUD="${INITIAL_BAUD:-115200}"
PROXY_LOG="${PROXY_LOG:-$ROOT/serial-proxy.log}"
UPDATE_SETTINGS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wineprefix)
            WINEPREFIX_DIR="$2"
            shift 2
            ;;
        --estlcam-path)
            ESTLCAM_PATH="$2"
            shift 2
            ;;
        --device)
            SERIAL_DEVICE="$2"
            shift 2
            ;;
        --com-port)
            COM_PORT="$2"
            shift 2
            ;;
        --baud)
            INITIAL_BAUD="$2"
            shift 2
            ;;
        --log)
            PROXY_LOG="$2"
            shift 2
            ;;
        --no-settings-update)
            UPDATE_SETTINGS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$COM_PORT" != COM* ]]; then
    echo "--com-port must look like COM4" >&2
    exit 2
fi

COM_NUMBER="${COM_PORT#COM}"
COM_LOWER="com${COM_NUMBER}"
DOSDEVICES="$WINEPREFIX_DIR/dosdevices"
SETTINGS_FILE="$WINEPREFIX_DIR/drive_c/ProgramData/Estlcam/V11/Settings CNC 11_100.txt"
PTY_FILE="/tmp/estlcam-proxy-pty.$$"
PROXY_STDERR="/tmp/estlcam-proxy-stderr.$$"
PROXY_PID=""

cleanup() {
    if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    rm -f "$PTY_FILE" "$PROXY_STDERR"
}
trap cleanup EXIT

if [[ ! -d "$WINEPREFIX_DIR" ]]; then
    echo "Wine prefix does not exist: $WINEPREFIX_DIR" >&2
    exit 1
fi

if [[ ! -e "$SERIAL_DEVICE" ]]; then
    echo "Serial device does not exist: $SERIAL_DEVICE" >&2
    exit 1
fi

if [[ ! -r "$ROOT/wine_tiocm_pty_shim.so" ]]; then
    echo "Missing wine_tiocm_pty_shim.so. Run: make" >&2
    exit 1
fi

python3 -u "$ROOT/serial_proxy.py" \
    --device "$SERIAL_DEVICE" \
    --baud "$INITIAL_BAUD" \
    --log "$PROXY_LOG" \
    > "$PTY_FILE" \
    2> "$PROXY_STDERR" &
PROXY_PID=$!

for _ in {1..80}; do
    if [[ -s "$PTY_FILE" ]]; then
        break
    fi
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        cat "$PROXY_STDERR" >&2 || true
        exit 1
    fi
    sleep 0.1
done

if [[ ! -s "$PTY_FILE" ]]; then
    echo "serial proxy did not report a PTY" >&2
    cat "$PROXY_STDERR" >&2 || true
    exit 1
fi

PTY="$(head -n 1 "$PTY_FILE")"
mkdir -p "$DOSDEVICES"
ln -sfn "$PTY" "$DOSDEVICES/$COM_LOWER"

WINEPREFIX="$WINEPREFIX_DIR" wine reg add \
    'HKLM\Software\Wine\Ports' \
    /v "$COM_PORT" \
    /t REG_SZ \
    /d "$PTY" \
    /f >/dev/null

if [[ "$UPDATE_SETTINGS" -eq 1 && -f "$SETTINGS_FILE" ]]; then
    sed -i "s/^Port=COM[0-9][0-9]*/Port=$COM_PORT/" "$SETTINGS_FILE"
fi

echo "Using $COM_PORT -> $PTY -> $SERIAL_DEVICE"
echo "Proxy log: $PROXY_LOG"

WINEPREFIX="$WINEPREFIX_DIR" \
LD_PRELOAD="$ROOT/wine_tiocm_pty_shim.so" \
wine "$ESTLCAM_PATH"
