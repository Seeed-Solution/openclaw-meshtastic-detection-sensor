#!/usr/bin/env bash
#
# Meshtastic Detection — One-click setup
#
# Usage:
#   ./setup.sh                              # auto-detect serial port
#   ./setup.sh /dev/cu.usbmodem1234567      # specify serial port
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SERIAL_PORT="${1:-}"

# ── Color helpers ──────────────────────────────────────────────
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
info()   { printf '  → %s\n' "$*"; }

echo ""
green "═══════════════════════════════════════════"
green "  Meshtastic Detection — Setup"
green "═══════════════════════════════════════════"
echo ""

# ── Step 1: Find Python 3.10+ ─────────────────────────────────
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" &>/dev/null; then
    ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
    major="${ver%%.*}"
    minor="${ver#*.}"
    if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
      PYTHON="$candidate"
      break
    fi
  fi
done

if [[ -z "$PYTHON" ]]; then
  red "Error: Python 3.10+ not found."
  echo "  macOS: brew install python@3.12"
  echo "  Linux: sudo apt install python3.12 python3.12-venv"
  exit 1
fi

info "Using Python: $PYTHON ($($PYTHON --version 2>&1))"

# ── Step 2: Create venv ───────────────────────────────────────
if [[ ! -d venv ]]; then
  info "Creating virtual environment..."
  "$PYTHON" -m venv venv
else
  info "Virtual environment already exists"
fi

# ── Step 3: Install dependencies ──────────────────────────────
info "Installing Python dependencies..."
./venv/bin/pip install -q -r requirements.txt

# ── Step 4: Create data directory ─────────────────────────────
mkdir -p data

# ── Step 5: Detect serial port ────────────────────────────────
if [[ -z "$SERIAL_PORT" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    SERIAL_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)
  else
    SERIAL_PORT=$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -1 || true)
  fi
fi

# ── Step 6: Test connection ───────────────────────────────────
if [[ -n "$SERIAL_PORT" ]]; then
  info "Detected serial port: $SERIAL_PORT"
  info "Testing Meshtastic connection..."
  if ./venv/bin/python -c "
import meshtastic, meshtastic.serial_interface
try:
    iface = meshtastic.serial_interface.SerialInterface('$SERIAL_PORT')
    info = iface.getMyNodeInfo()
    user = info.get('user', {})
    print(f'  Connected: {user.get(\"longName\", \"unknown\")} ({user.get(\"id\", \"?\")})')
    iface.close()
except Exception as e:
    print(f'  Warning: {e}')
" 2>/dev/null; then
    :
  else
    yellow "  Connection test failed — check USB cable and device"
  fi
else
  yellow "  No Meshtastic USB device detected"
  echo "  Plug in your device and re-run, or specify the port:"
  echo "  ./setup.sh /dev/cu.usbmodemXXXX"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
green "Setup complete!"
echo ""
echo "  Start the receiver:"
if [[ -n "$SERIAL_PORT" ]]; then
  echo "    ./venv/bin/python scripts/usb_receiver.py --port $SERIAL_PORT"
else
  echo "    ./venv/bin/python scripts/usb_receiver.py --port <your-serial-port>"
fi
echo ""
echo "  Check alerts:"
echo "    ./venv/bin/python scripts/event_monitor.py"
echo ""
echo "  Query data:"
echo "    ./venv/bin/python scripts/sensor_cli.py latest"
echo ""
echo "  For feishu cron setup, see: references/SETUP.md (Step 7)"
echo ""
