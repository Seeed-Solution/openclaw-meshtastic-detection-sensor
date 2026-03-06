# meshtastic-detection

Meshtastic Detection Sensor alert receiver via LoRa -- USB serial, local JSONL storage, feishu notifications.

## Overview

An OpenClaw skill that connects to a Meshtastic LoRa device via USB to receive `DETECTION_SENSOR_APP` events from a remote sensor node. When the remote device's GPIO pin triggers (preset target detected), the event is stored locally and an alert is sent to feishu.

- **Receive** `DETECTION_SENSOR_APP` events over LoRa mesh (GPIO trigger)
- **Store** to local JSONL files (no database required)
- **Alert** immediately via feishu through OpenClaw cron
- **Query** through OpenClaw conversation or CLI

## Supported Platforms

| Platform | Serial port pattern | Service manager |
|----------|-------------------|-----------------|
| macOS | `/dev/cu.usbmodem*` | launchd (plist) |
| Linux x86/arm | `/dev/ttyUSB*`, `/dev/ttyACM*` | systemd |
| Raspberry Pi | `/dev/ttyUSB*`, `/dev/ttyACM*` | systemd |
| Docker | `/dev/ttyUSB*`, `/dev/ttyACM*` | entrypoint.sh + `nohup` / container CMD |

`setup.sh` auto-detects your platform (including Docker) and handles all differences.

## Architecture

```
Remote Sensor Device              Host Machine (macOS/Linux/RPi)
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
# 1. One-click setup (auto-detects platform, Python, serial port)
./setup.sh

# 2. Start receiver (Ctrl+C to stop)
#    macOS:
./venv/bin/python scripts/usb_receiver.py --port /dev/cu.usbmodem1CDBD4A896441
#    Linux/RPi:
./venv/bin/python scripts/usb_receiver.py --port /dev/ttyUSB0

# 3. Check for alerts (in another terminal)
./venv/bin/python scripts/event_monitor.py

# 4. Query historical data
./venv/bin/python scripts/sensor_cli.py latest
./venv/bin/python scripts/sensor_cli.py stats --since 1h
```

需要飞书告警时，按下方 **「OpenClaw Cron Alert (feishu)」** 配置定时任务即可。

## Install as System Service

`setup.sh` automatically generates a service file for your platform. Follow the output instructions, or:

**Linux / Raspberry Pi (systemd):**
```bash
sudo cp meshtastic-detection.generated.service /etc/systemd/system/meshtastic-detection.service
sudo systemctl daemon-reload
sudo systemctl enable --now meshtastic-detection

# Check status
sudo systemctl status meshtastic-detection
sudo journalctl -u meshtastic-detection -f
```

**macOS (launchd):**
```bash
cp com.openclaw.meshtastic-detection.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.openclaw.meshtastic-detection.plist

# Uninstall
launchctl unload ~/Library/LaunchAgents/com.openclaw.meshtastic-detection.plist
```

**Docker (entrypoint.sh):**

容器内没有 systemd，`setup.sh` 检测到 Docker 后会生成 `entrypoint.sh`，它内置自动重启循环。

方式一：在已运行的容器内后台启动
```bash
nohup ./entrypoint.sh > data/entrypoint.log 2>&1 &

# 查看日志
tail -f data/entrypoint.log
```

方式二：作为容器主进程（推荐，由 Docker 管理重启）

```yaml
# docker-compose.yml
services:
  meshtastic:
    image: your-image
    working_dir: /app/skills/meshtastic-detection
    command: ./entrypoint.sh
    restart: always
    privileged: true
    devices:
      - /dev/ttyACM0:/dev/ttyACM0
    volumes:
      - ./data:/app/skills/meshtastic-detection/data
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

配置后，定时任务每分钟执行一次 `event_monitor.py`；若有新告警，OpenClaw 会通过飞书推送给你。

### 1. 添加定时任务

在项目根目录执行（将 `<项目路径>` 换成实际路径，如 `/Users/you/.openclaw/skills/meshtastic-detection`；将 `<your-feishu-open-id>` 换成你的飞书 open_id）：

```bash
openclaw cron add \
  --name "sensor-monitor" \
  --every 1m \
  --session isolated \
  --timeout-seconds 60 \
  --message "Run this command and report the output: cd <项目路径> && ./venv/bin/python scripts/event_monitor.py — If alert_count > 0, tell me how many alerts, the latest sender and time. If alert_count is 0, reply: 暂无新告警。" \
  --announce \
  --channel feishu \
  --to <your-feishu-open-id>
```

参数说明：
- `--every 1m`：每 1 分钟执行一次
- `--timeout-seconds 60`：单次执行超时 60 秒（跑脚本 + 发消息需要约 20–40 秒）
- `--channel feishu`：通过飞书发送
- `--to <open-id>`：飞书接收人的 open_id（必填，否则收不到消息）

### 2. 验证是否生效

```bash
# 查看所有定时任务
openclaw cron list

# 手动触发一次（把 <job-id> 换成列表里的 ID）
openclaw cron run <job-id>

# 查看该任务的执行历史
openclaw cron runs --id <job-id>
```

若飞书收不到消息：检查 `--to` 是否填了正确的飞书用户 open_id；超时可把 `--timeout-seconds` 调大。

## File Structure

```
meshtastic-detection/
├── _meta.json                    # ClawHub metadata
├── SKILL.md                      # AI agent instructions (with metadata gating)
├── CONFIG.md                     # User configuration
├── README.md                     # This file
├── setup.sh                      # One-click setup (macOS/Linux/RPi)
├── requirements.txt              # Python dependencies
├── .gitignore
├── scripts/
│   ├── usb_receiver.py           # USB serial daemon
│   ├── event_monitor.py          # Incremental alert monitor
│   └── sensor_cli.py             # Query CLI
├── data/                         # Runtime data (git-ignored)
│   ├── sensor_data.jsonl
│   ├── sensor_data.jsonl.1       # Archive
│   ├── sensor_data.jsonl.2       # Archive
│   ├── latest.json
│   └── monitor_state.json
├── docs/
│   └── OPENCLAW_SKILLS_GUIDE.md
└── references/
    ├── SETUP.md                  # Detailed installation guide
    ├── meshtastic-detection.service                # systemd template (Linux/RPi)
    ├── com.openclaw.meshtastic-detection.plist     # launchd template (macOS)
    └── entrypoint.sh                              # Docker entrypoint template
```

## Dependencies

- `meshtastic>=2.0` -- Meshtastic Python API
- `pypubsub` -- Pubsub for serial event handling
- Python 3.10+

| Platform | Install Python |
|----------|---------------|
| macOS | `brew install python@3.12` |
| Raspberry Pi | `sudo apt install python3.11 python3.11-venv` |
| Ubuntu/Debian | `sudo apt install python3.12 python3.12-venv` |

## Troubleshooting

**Docker 内运行 setup.sh：ensurepip 不可用 / 无 root**
- `setup.sh` 会先尝试创建「无 pip」的 venv，再用 get-pip.py 安装 pip，**不依赖 apt**，适合无 root 的容器。
- 若仍失败，请使用带完整 venv 的镜像（如 `python:3.11`）或以 root 在镜像内先执行：`apt update && apt install -y python3.11-venv`。

**Docker 串口访问（/dev/ttyACM0 权限问题）**
- 在宿主机将设备挂载进容器：
  - `docker run --device /dev/ttyACM0:/dev/ttyACM0 ...`
  - 或在 compose 中：
    - `devices:`
      - `/dev/ttyACM0:/dev/ttyACM0`
- 若仍报 `Permission denied`，可以临时使用特权容器（测试环境推荐）：
  - `docker run --privileged ...`
  - 或在 compose 中：`privileged: true`
- 生产环境更安全的做法是只挂载需要的设备，并避免长期使用 `privileged: true`。

**Raspberry Pi / Debian: ensurepip not available**
- `setup.sh` will auto-detect and install the missing `python3.X-venv` package via apt.
- If auto-install fails, run manually: `sudo apt install python3.11-venv` (replace `3.11` with your Python version).

**Raspberry Pi: serial port permission denied**
- Add your user to the `dialout` group: `sudo usermod -a -G dialout $USER`
- Log out and back in (or reboot) for the change to take effect.

**venv install fails with pyobjc-core error (macOS)**
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
- Only one process can use the port.
- macOS: `lsof /dev/cu.usbmodem*`
- Linux/RPi: `lsof /dev/ttyUSB* /dev/ttyACM*`

## License

MIT
