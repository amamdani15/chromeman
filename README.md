# chromeman

A single-file bash utility for managing fullscreen Chrome kiosk windows across multiple Ubuntu virtual desktops. Designed for AV/production environments where you need persistent, auto-recovering browser displays — like a house of worship, lobby signage, or a broadcast control room.

Features a built-in watchdog that checks every N minutes and relaunches any dead windows, a pause/resume system for intentional shutdowns, and an HTTP API so tools like Bitfocus Companion can trigger restarts from a physical button.

---

## Requirements

- Ubuntu (tested on Ubuntu 22.04/24.04, X11 session — see [Wayland note](#wayland))
- `google-chrome` or `chromium-browser`
- `wmctrl` — `sudo apt install wmctrl`
- `netcat-openbsd` — `sudo apt install netcat-openbsd` *(HTTP server only)*
- `python3` *(standard on Ubuntu — used for URL decoding in HTTP server)*

> **Important:** The workspace-switching features require an **X11** session. At the Ubuntu login screen, click the gear icon and select **"Ubuntu on Xorg"** before logging in.

---

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/yourname/chromeman.git
cd chromeman

# 2. Install dependencies
sudo apt install wmctrl netcat-openbsd

# 3. Make the script executable
chmod +x chromeman.sh

# 4. (Optional) Install globally so you can call it from anywhere
sudo cp chromeman.sh /usr/local/bin/chromeman
```

---

## Quick Start

```bash
# Generate a config file at ~/chrome-manager/chrome-displays.conf
chromeman init

# Edit the config — set your workspace numbers and URLs
nano ~/chrome-manager/chrome-displays.conf

# Launch all displays and start the watchdog
chromeman start

# Check status
chromeman status

# Shut everything down
chromeman stop
```

---

## Config File

The config file defines each Chrome window. By default it lives at `~/chrome-manager/chrome-displays.conf`. A different path can be specified with `--config`.

```ini
# Each display needs three keys, numbered from 1

DISPLAY_1_WORKSPACE=1          # which virtual desktop (1-indexed)
DISPLAY_1_URL=https://example.com
DISPLAY_1_PROFILE=chrome-kiosk-1  # unique Chrome profile name (no spaces)

DISPLAY_2_WORKSPACE=2
DISPLAY_2_URL=https://other.com
DISPLAY_2_PROFILE=chrome-kiosk-2

DISPLAY_3_WORKSPACE=3
DISPLAY_3_URL=https://third.com
DISPLAY_3_PROFILE=chrome-kiosk-3
```

See [`examples/chrome-displays.conf`](examples/chrome-displays.conf) for an annotated example.

**Rules:**
- Numbers must start at `1` and be contiguous (`1, 2, 3` — not `1, 3`)
- Each `PROFILE` value must be unique — Chrome data is stored at `~/.config/<PROFILE>`
- Restart chromeman after editing the file (`chromeman restart`)

---

## Commands

| Command | Description |
|---|---|
| `start` | Launch all displays and start the watchdog |
| `stop` | Stop the watchdog and close all Chrome windows |
| `restart` | `stop` then `start` |
| `pause` | Close one display and tell the watchdog to leave it alone |
| `resume` | Re-enable and relaunch a paused display |
| `status` | Show the running state of every display and the watchdog |
| `watch` | Run the watchdog loop in the foreground (used internally) |
| `http-server` | Start the HTTP API for Companion integration |
| `install` | Register the watchdog as a systemd user service |
| `install-http` | Register the HTTP server as a systemd user service |
| `uninstall` | Remove the watchdog systemd service |
| `uninstall-http` | Remove the HTTP server systemd service |
| `init` | Create a default config file |
| `log` | Tail the watchdog log live |

---

## Options

| Flag | Default | Description |
|---|---|---|
| `-c, --config FILE` | `~/chrome-manager/chrome-displays.conf` | Path to config file |
| `-i, --interval SEC` | `600` | Watchdog check interval in seconds |
| `-p, --port PORT` | `7070` | HTTP server port |
| `-d, --display N` | — | Target a single display by number |
| `-u, --url URL` | — | Override URL at runtime (does not save to config) |
| `-n, --no-restart` | — | With `stop -d N`: prevent watchdog from relaunching |
| `-h, --help` | — | Show help |
| `-v, --version` | — | Show version |

---

## Usage Examples

### Basic operations

```bash
# Start everything defined in the config
chromeman start

# Start only display 2
chromeman start -d 2

# Start display 2 with a URL different from the config (one-time override)
chromeman start -d 2 -u https://override.example.com

# Stop everything
chromeman stop

# Stop only display 3 — watchdog will relaunch it at next check
chromeman stop -d 3

# Stop display 3 permanently — watchdog will NOT relaunch it
chromeman stop -d 3 --no-restart

# Restart everything
chromeman restart

# Restart just display 1 with a new URL
chromeman restart -d 1 -u https://new.example.com
```

### Pause and resume

`pause` is the clean way to take a display offline without stopping the whole system. The watchdog will ignore paused displays until you explicitly resume them.

```bash
# Take display 2 offline — watchdog ignores it
chromeman pause -d 2

# Bring it back with the original config URL
chromeman resume -d 2

# Bring it back with a different URL
chromeman resume -d 2 -u https://different.example.com
```

`chromeman status` will show paused displays with a `⏸` indicator:

```
  ●  Display 1   https://livestream.example.com    PIDs: 12345
  ⏸  Display 2   https://fundraiser.example.com    paused
  ○  Display 3   https://schedule.example.com      not running

  ●  Watchdog running  (PID 9876, interval: 600s)
```

### Watchdog

The watchdog is started automatically by `chromeman start`. It checks every display at the configured interval and relaunches any that have died.

```bash
# Change the check interval to 2 minutes
chromeman start -i 120

# Or run the watchdog manually in the foreground (useful for debugging)
chromeman watch -i 60
```

Watchdog events are logged to `~/chrome-manager/chromeman.log`. Tail it live:

```bash
chromeman log
```

### Using a custom config path

```bash
chromeman start -c /etc/chromeman/displays.conf
chromeman status -c /etc/chromeman/displays.conf
```

---

## Auto-start on Login (systemd)

Register chromeman as a systemd user service so it starts automatically when you log into your desktop session.

```bash
# Install the watchdog service
chromeman install
systemctl --user start chromeman

# Install the HTTP server service (if using Companion)
chromeman install-http
systemctl --user start chromeman-http

# Check service status
systemctl --user status chromeman
systemctl --user status chromeman-http

# View logs via journald
journalctl --user -u chromeman -f
journalctl --user -u chromeman-http -f

# Remove services
chromeman uninstall
chromeman uninstall-http
```

> **Note:** systemd user services require `loginctl enable-linger $USER` to run without an active login session. For a typical desktop kiosk where a user is always logged in, this is not needed.

---

## Bitfocus Companion Integration

chromeman includes a built-in HTTP server that Companion can trigger via GET requests.

### Setup

```bash
# Start the HTTP server manually
chromeman http-server

# Or install as a persistent service
chromeman install-http
systemctl --user start chromeman-http
```

The server listens on port `7070` by default. Change it with `--port`:

```bash
chromeman http-server -p 8080
chromeman install-http -p 8080
```

### Endpoints

All endpoints accept GET requests.

| Endpoint | Action |
|---|---|
| `/restart` | Restart all displays |
| `/restart?d=2` | Restart display 2 |
| `/restart?d=2&url=https%3A%2F%2Fexample.com` | Restart display 2 with a URL override |
| `/start` | Start all displays |
| `/start?d=2` | Start display 2 |
| `/stop` | Stop all displays |
| `/stop?d=2` | Stop display 2 (watchdog will relaunch) |
| `/pause?d=2` | Pause display 2 |
| `/resume?d=2` | Resume display 2 |
| `/resume?d=2&url=https%3A%2F%2Fexample.com` | Resume display 2 with a URL override |
| `/status` | Returns JSON state of all displays |

The `url` parameter must be URL-encoded. You can encode a URL quickly with:

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote('https://your-url.com'))"
```

### `/status` response

```json
{
  "displays": [
    { "display": 1, "url": "https://livestream.example.com", "state": "running" },
    { "display": 2, "url": "https://fundraiser.example.com", "state": "paused" },
    { "display": 3, "url": "https://schedule.example.com",  "state": "stopped" }
  ],
  "watchdog": "running"
}
```

### Setting up in Companion

1. In Companion, go to **Connections** and add **Generic: HTTP Requests**
2. Set the base URL to `http://<machine-ip>:7070`
3. Create buttons with the following GET request paths:

| Button label | Request path |
|---|---|
| Restart All | `/restart` |
| Restart Screen 1 | `/restart?d=1` |
| Restart Screen 2 | `/restart?d=2` |
| Restart Screen 3 | `/restart?d=3` |
| Pause Screen 2 | `/pause?d=2` |
| Resume Screen 2 | `/resume?d=2` |
| Show Fundraiser | `/restart?d=2&url=https%3A%2F%2Ffundraiser.example.com` |

Companion will receive an immediate `200 OK` response with a plain-text confirmation like `OK: chromeman restart -d 2`. The chromeman command runs asynchronously in the background so Companion never times out waiting for Chrome to launch.

---

## File Structure

After first run, chromeman creates the following in `~/chrome-manager/`:

```
~/chrome-manager/
├── chrome-displays.conf   # your config file
├── chromeman.log          # watchdog + HTTP server log
├── watchdog.pid           # PID of the running watchdog process
├── http-server.pid        # PID of the running HTTP server process
└── paused/                # pause lock files (one per paused profile)
    └── chrome-kiosk-2     # example: display 2 is paused
```

Chrome profile data (cache, cookies, session) is stored separately at:

```
~/.config/chrome-kiosk-1/
~/.config/chrome-kiosk-2/
~/.config/chrome-kiosk-3/
```

These are isolated from your main Chrome profile, so kiosk sessions never interfere with your regular browser.

---

## Troubleshooting

### Windows land on the wrong workspace

This is almost always a Wayland issue. Check:

```bash
echo $XDG_SESSION_TYPE
```

If it says `wayland`, log out and select **"Ubuntu on Xorg"** at the login screen. `wmctrl` does not support Wayland workspace management.

### Chrome command not found

Depending on how Chrome is installed, the binary name may differ:

```bash
which google-chrome        # standard .deb install
which chromium-browser     # Snap / apt chromium
which chromium             # some distros
```

Edit `launch_one()` in `chromeman.sh` and update the `google-chrome` line to match.

### Snap-installed Chrome: window not found

Snap wraps Chrome in a container which can cause PID mismatches. chromeman includes a profile-path fallback for this case, but if windows still aren't being placed correctly, try switching to the `.deb` version of Chrome from Google's repo instead of the Snap.

### Watchdog relaunches a display that keeps crashing

If a URL is broken or the page crashes Chrome on load, the watchdog will keep trying. Fix the URL in the config first, then run `chromeman restart`.

### HTTP server not responding

Check that `nc` is installed and is the OpenBSD variant (not traditional netcat):

```bash
sudo apt install netcat-openbsd
nc --version   # should say "OpenBSD netcat"
```

Also verify the port isn't blocked by a firewall:

```bash
sudo ufw allow 7070/tcp
```

### Checking what's running manually

```bash
# Show all chromeman-related processes
pgrep -a -f "chrome-kiosk"

# List all windows and their workspace
wmctrl -l

# Check systemd service status
systemctl --user status chromeman
systemctl --user status chromeman-http
```

---

## Wayland

`wmctrl` — which chromeman uses to move windows between workspaces — does not work under Wayland. The script will launch Chrome but cannot guarantee it lands on the correct virtual desktop.

**Workaround:** Use an X11 session. At the Ubuntu login screen, click the gear icon (⚙) in the bottom-right and select **"Ubuntu on Xorg"**.

Native Wayland support (via `ydotool` or `swaymsg`) may be added in a future version.

---

## Repository Layout

```
chromeman/
├── chromeman.sh           # the utility (single file, no dependencies beyond bash)
├── README.md              # this file
└── examples/
    └── chrome-displays.conf   # annotated example config
```

---

## License

MIT
