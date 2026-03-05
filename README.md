# meshtastic-detection

Meshtastic Detection Sensor alert receiver via LoRa -- USB serial, local JSONL storage, feishu notifications.

## Overview

An OpenClaw skill that connects to a Meshtastic LoRa device via USB to receive `DETECTION_SENSOR_APP` events from a remote sensor node. When the remote device's GPIO pin triggers (preset target detected), the event is stored locally and an alert is sent to feishu.

- **Receive** `DETECTION_SENSOR_APP` events over LoRa mesh (GPIO trigger)
- **Store** to local JSONL files (no database required)
- **Alert** immediately via feishu through OpenClaw cron
- **Query** through OpenClaw conversation or CLI

## Architecture

```
Remote Sensor Device              Host Machine (macOS/Linux)
[GPIO Detection Sensor]           [Meshtastic Module via USB]
        |                                  |
        | LoRa radio                  usb_receiver.py (daemon)
        |                                  |
        └──────────────────────────────────┘
                                           |
                                    data/sensor_data.jsonl
                                           |
                              ┌────────────┼────────────┐
                              │            │            │
                        sensor_cli.py  event_monitor  OpenClaw cron
                        (query data)   (check new)    (feishu alert)
```

## Quick Start

```bash
# 1. One-click setup (auto-detects Python 3.10+ and serial port)
./setup.sh

# 2. Start receiver (Ctrl+C to stop)
./venv/bin/python scripts/usb_receiver.py --port /dev/cu.usbmodem1CDBD4A896441

# 3. Check for alerts (in another terminal)
./venv/bin/python scripts/event_monitor.py

# 4. Query historical data
./venv/bin/python scripts/sensor_cli.py latest
./venv/bin/python scripts/sensor_cli.py stats --since 1h
```

## Components

| Component | Purpose |
|-----------|---------|
| `usb_receiver.py` | Long-running daemon: USB serial -> JSONL storage (DETECTION_SENSOR_APP only) |
| `event_monitor.py` | Incremental alert checker: reads new records since last check, outputs JSON |
| `sensor_cli.py` | CLI query tool: latest, query, stats, status |
| `SKILL.md` | OpenClaw skill definition (agent reads this) |
| `CONFIG.md` | User configuration (serial port, notification channel) |

## Data Format

Each detection record in `data/sensor_data.jsonl`:

```json
{"received_at": "2026-03-04T11:07:06+00:00", "sender": "!1dd29c50", "channel": "ch0", "portnum": "DETECTION_SENSOR_APP", "data": {"type": "detection", "text": "alert detected"}}
```

Only `DETECTION_SENSOR_APP` messages are captured. Every record = a GPIO trigger on the remote sensor.

## Log Rotation

`sensor_data.jsonl` is automatically rotated when it exceeds **5 MB**:

- Current file -> `sensor_data.jsonl.1` -> `sensor_data.jsonl.2` (oldest deleted)
- At most **2 archive files** are kept (total max ~15 MB on disk)
- `event_monitor` state is automatically reset after rotation
- `sensor_cli` reads across all archive files for complete query results

No manual cleanup needed.

## OpenClaw Cron Alert (feishu)

The cron job runs `event_monitor.py` every 60 seconds. If there are new detections, OpenClaw sends the alert to feishu.

```bash
# Check cron status
openclaw cron list

# View run history
openclaw cron runs --id <job-id>

# Manual test run
openclaw cron run <job-id>
```

Key cron config that was needed:
- `timeoutSeconds: 60` (agent needs ~20-40s to run script + compose message)
- `delivery.to: ou_xxx` (feishu user open_id)
- `delivery.channel: feishu`

## File Structure

```
meshtastic-detection/
├── _meta.json                    # ClawHub metadata
├── SKILL.md                      # AI agent instructions (with metadata gating)
├── CONFIG.md                     # User configuration
├── README.md                     # This file
├── setup.sh                      # One-click setup script
├── requirements.txt              # Python dependencies
├── .gitignore                    # Excludes venv/ and data/ runtime files
├── scripts/
│   ├── usb_receiver.py           # USB serial daemon (DETECTION_SENSOR_APP only)
│   ├── event_monitor.py          # Incremental alert monitor
│   └── sensor_cli.py             # Query CLI
├── data/                         # Runtime data (auto-rotated, git-ignored)
│   ├── sensor_data.jsonl         # Current detection records
│   ├── sensor_data.jsonl.1       # Archive (previous rotation)
│   ├── sensor_data.jsonl.2       # Archive (oldest, auto-deleted)
│   ├── latest.json               # Most recent detection
│   └── monitor_state.json        # Monitor byte offset + seen hashes
├── docs/
│   └── OPENCLAW_SKILLS_GUIDE.md  # OpenClaw Skills 配置与发布指南
└── references/
    ├── SETUP.md                  # Detailed installation guide
    └── meshtastic-detection.service # systemd template (Linux)
```

## Dependencies

- `meshtastic>=2.0` -- Meshtastic Python API
- `pypubsub` -- Pubsub for serial event handling
- Python 3.10+ (macOS users: use `python3.12`, not the system `python3`)

## Troubleshooting

**venv install fails with pyobjc-core error**
- You're using Python 3.9 (macOS default). Recreate with `python3.12 -m venv venv`.

**Receiver runs but no detection events appear**
- Only `DETECTION_SENSOR_APP` messages are captured (not TEXT_MESSAGE_APP).
- Run with `--debug` to see all incoming packets.
- Confirm the remote device has Detection Sensor Settings configured (GPIO pin monitoring).
- Both devices must be on the same Meshtastic channel with the same encryption key.

**Cron job times out**
- Increase `timeoutSeconds` to 60 via `openclaw cron edit <id> --timeout-seconds 60`.

**Cron runs but feishu doesn't receive message**
- Set delivery target: `openclaw cron edit <id> --to <feishu-open-id>`.

**Serial port busy**
- Only one process can use the port. Check: `lsof /dev/cu.usbmodem*`.

## License

MIT
