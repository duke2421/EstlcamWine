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
  --modem-lines MODE      stable or forward, default: stable
  --skip-device-check     Do not warn if the serial device is already open
  --no-settings-update    Do not edit Estlcam's Settings CNC file
  -h, --help              Show this help

Environment variables with the same names are also supported:
  WINEPREFIX, ESTLCAM_PATH, SERIAL_DEVICE, COM_PORT, INITIAL_BAUD, PROXY_LOG,
  MODEM_LINES
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="${WINEPREFIX:-$HOME/.wine}"
ESTLCAM_PATH="${ESTLCAM_PATH:-C:\\Program Files (x86)\\Estlcam11\\Estlcam.exe}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyUSB0}"
COM_PORT="${COM_PORT:-COM4}"
INITIAL_BAUD="${INITIAL_BAUD:-115200}"
PROXY_LOG="${PROXY_LOG:-$ROOT/serial-proxy.log}"
MODEM_LINES="${MODEM_LINES:-stable}"
UPDATE_SETTINGS=1
CHECK_DEVICE=1

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
        --modem-lines)
            MODEM_LINES="$2"
            shift 2
            ;;
        --skip-device-check)
            CHECK_DEVICE=0
            shift
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

if [[ "$MODEM_LINES" != "stable" && "$MODEM_LINES" != "forward" ]]; then
    echo "--modem-lines must be stable or forward" >&2
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

update_estlcam_settings() {
    if [[ "$UPDATE_SETTINGS" -ne 1 || ! -f "$SETTINGS_FILE" ]]; then
        return
    fi

    sed -i \
        -e "s/^Enabled=.*/Enabled=yes/" \
        -e "s/^Port=COM[0-9][0-9]*/Port=$COM_PORT/" \
        "$SETTINGS_FILE"
}

set_wine_com_mapping() {
    local target="$1"
    local actual=""

    mkdir -p "$DOSDEVICES"

    WINEPREFIX="$WINEPREFIX_DIR" wine reg add \
        'HKLM\Software\Wine\Ports' \
        /v "$COM_PORT" \
        /t REG_SZ \
        /d "$target" \
        /f >/dev/null

    ln -sfn "$target" "$DOSDEVICES/$COM_LOWER"
    actual="$(readlink "$DOSDEVICES/$COM_LOWER" || true)"
    if [[ "$actual" != "$target" ]]; then
        echo "Failed to map $COM_PORT to $target; $DOSDEVICES/$COM_LOWER points to ${actual:-nothing}" >&2
        exit 1
    fi
}

check_serial_device_available() {
    if [[ "$CHECK_DEVICE" -ne 1 ]]; then
        return
    fi

    local users=""
    if command -v lsof >/dev/null 2>&1; then
        users="$(lsof -n -- "$SERIAL_DEVICE" 2>/dev/null || true)"
    elif command -v fuser >/dev/null 2>&1; then
        users="$(fuser -v "$SERIAL_DEVICE" 2>&1 || true)"
    else
        echo "Warning: cannot check whether $SERIAL_DEVICE is already open; install lsof or psmisc/fuser." >&2
        return
    fi

    if [[ -n "$users" ]]; then
        cat >&2 <<EOF
Warning: $SERIAL_DEVICE appears to be open already.

$users

Close other Estlcam/Wine/proxy/serial-monitor processes before continuing.
Use --skip-device-check to ignore this warning.
EOF
        exit 1
    fi
}

if [[ ! -d "$WINEPREFIX_DIR" ]]; then
    echo "Wine prefix does not exist: $WINEPREFIX_DIR" >&2
    exit 1
fi

if [[ ! -e "$SERIAL_DEVICE" ]]; then
    echo "Serial device does not exist: $SERIAL_DEVICE" >&2
    exit 1
fi

check_serial_device_available

if [[ "$MODEM_LINES" == "forward" ]]; then
    set_wine_com_mapping "$SERIAL_DEVICE"
    update_estlcam_settings

    echo "Using $COM_PORT -> $SERIAL_DEVICE directly"
    echo "Wine dosdevice: $DOSDEVICES/$COM_LOWER -> $(readlink "$DOSDEVICES/$COM_LOWER")"
    echo "Modem lines: forward"
    echo "Proxy: disabled for firmware flashing"

    WINEPREFIX="$WINEPREFIX_DIR" \
    WINEDEBUG="${WINEDEBUG:--comm}" \
    wine "$ESTLCAM_PATH"
    exit $?
fi

if [[ ! -r "$ROOT/wine_tiocm_pty_shim.so" ]]; then
    echo "Missing wine_tiocm_pty_shim.so. Run: make" >&2
    exit 1
fi

PROXY_ARGS=(
    "$ROOT/serial_proxy.py"
    --device "$SERIAL_DEVICE"
    --baud "$INITIAL_BAUD"
    --log "$PROXY_LOG"
)

python3 -u "${PROXY_ARGS[@]}" > "$PTY_FILE" 2> "$PROXY_STDERR" &
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
set_wine_com_mapping "$PTY"
update_estlcam_settings

echo "Using $COM_PORT -> $PTY -> $SERIAL_DEVICE"
echo "Wine dosdevice: $DOSDEVICES/$COM_LOWER -> $(readlink "$DOSDEVICES/$COM_LOWER")"
echo "Proxy log: $PROXY_LOG"
echo "Modem lines: $MODEM_LINES"

WINEPREFIX="$WINEPREFIX_DIR" \
WINEDEBUG="${WINEDEBUG:--comm}" \
LD_PRELOAD="$ROOT/wine_tiocm_pty_shim.so" \
wine "$ESTLCAM_PATH"
