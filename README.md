# chromeman

A single-file bash utility for managing fullscreen Chrome kiosk windows pinned to specific physical monitors on Ubuntu. Designed for AV/production environments where you need persistent, auto-recovering browser displays — like a house of worship, lobby signage, or a broadcast control room.

Features a built-in watchdog that checks every N minutes and relaunches any dead windows, a pause/resume system for intentional shutdowns, and an HTTP API so tools like Bitfocus Companion can trigger restarts from a physical button.

---

## Requirements

- Ubuntu (tested on Ubuntu 22.04/24.04, X11 session — see [Wayland note](#wayland))
- `google-chrome` or `chromium-browser`
- `wmctrl` — `sudo apt install wmctrl`
- `xrandr` — `sudo apt install x11-xserver-utils` *(used to find/verify monitor outputs; usually preinstalled)*
- `netcat-openbsd` — `sudo apt install netcat-openbsd` *(HTTP server only)*
- `python3` *(standard on Ubuntu — used for URL decoding in HTTP server)*

> **Important:** Window placement requires an **X11** session. At the Ubuntu login screen, click the gear icon and select **"Ubuntu on Xorg"** before logging in.

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
# See your monitor output names (e.g. DP-7, DP-1, DP-3)
chromeman outputs

# Generate a config file at ~/chrome-manager/chrome-displays.conf
chromeman init

# Edit the config — set your monitor outputs and URLs
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

DISPLAY_1_OUTPUT=DP-7           # physical monitor (xrandr output name)
DISPLAY_1_URL=https://example.com
DISPLAY_1_PROFILE=chrome-kiosk-1  # unique Chrome profile name (no spaces)

DISPLAY_2_OUTPUT=DP-1
DISPLAY_2_URL=https://other.com
DISPLAY_2_PROFILE=chrome-kiosk-2

DISPLAY_3_OUTPUT=DP-3
DISPLAY_3_URL=https://third.com
DISPLAY_3_PROFILE=chrome-kiosk-3
```

See [`examples/chrome-displays.conf`](examples/chrome-displays.conf) for an annotated example.

**Rules:**
- Numbers must start at `1` and be contiguous (`1, 2, 3` — not `1, 3`)
- Each `PROFILE` value must be unique — Chrome data is stored at `~/.config/<PROFILE>`
- `OUTPUT` must match an xrandr output name exactly (run `chromeman outputs` to list them)
- Restart chromeman after editing the file (`chromeman restart`)

---

## Monitor Outputs

chromeman pins each Chrome window to a specific physical monitor using its **xrandr output name** (e.g. `DP-7`, `DP-1`, `DP-3`). Run:

```bash
chromeman outputs
```

This prints the connected monitors and their output names — use the name from the rightmost column as `DISPLAY_N_OUTPUT`.

### Will the output names change after a reboot or reconnect?

Output names are tied to the **physical GPU port** the cable is plugged into, not to the monitor itself or the order things power on. As long as each cable stays in the same port on the graphics card, `DP-7` will always be `DP-7` — even if the monitors are slower to wake up or initialize in a different order on boot.

**To keep things consistent:**
- **Label the cables/ports** — physically mark which DisplayPort/mini-DP output on the GPU corresponds to which output name (e.g. with a sticker: "DP-7"), so if a cable ever gets unplugged for maintenance, it goes back in the right port.
- **Don't swap cables between ports** — if a monitor is moved to a different GPU port, its output name changes and the config will no longer match.
- **Run `chromeman outputs` after any hardware change** (new monitor, reseated cable, reboot after a power outage) to confirm the names still match your config.

`chromeman start` and the watchdog (`chromeman watch`) automatically run a check on every cycle: if a configured output isn't currently detected by `xrandr`, a warning is printed/logged (`chromeman log`) naming the missing output and listing what's currently connected. That display will still attempt to launch, but without monitor-specific placement — keep an eye out for these warnings after any hardware change.

### Forcing a resolution (`chromeman lock-resolutions`)

#### Why this exists

Some monitors — especially ones behind converters/switchers (e.g. Blackmagic Design HDMI boxes) — report a misleading **EDID-"preferred" mode** (often `1920x1080`) even though they support 4K. GNOME/mutter applies that preferred mode at every login, boot, or hotplug, which can silently downgrade a display you'd manually set to 4K. It can also shrink the X **virtual screen** size so other outputs can't be resized either, causing `xrandr`/`nvidia-settings` to fail with `BadMatch (RRSetScreenSize)`.

`chromeman lock-resolutions` + the automatic `apply_modes` step (run by `chromeman start`/`watch`) fix this in two parts:

1. **`lock-resolutions`** (one-time, manual, needs reboot) — raises the X virtual screen size *ceiling* by writing `Option "metamodes"` + `Virtual W H` into `/etc/X11/xorg.conf`, so the resolutions you want are actually possible.
2. **`apply_modes`** (automatic, every `start`/`restart`/watchdog cycle) — runs `xrandr` to re-apply your chosen resolutions and positions, since GNOME/mutter will otherwise reset them to EDID-preferred on every login.

You need **both**. `lock-resolutions` alone doesn't make the resolution stick (mutter overrides it after login); `apply_modes` alone can't exceed whatever virtual screen size X already has (hence `BadMatch`).

#### Before running it for the first time

1. **Confirm `/etc/X11/xorg.conf` exists and uses the `nvidia` driver:**
   ```bash
   cat /etc/X11/xorg.conf
   ```
   If the file doesn't exist, generate one first, then reboot before continuing:
   ```bash
   sudo nvidia-xconfig
   sudo reboot
   ```
   (`lock-resolutions` edits this file's `Screen` section — it does **not** create it from scratch.)

2. **Figure out which outputs need forcing, and to what resolution.** Run:
   ```bash
   chromeman outputs       # currently active monitors + their geometry
   chromeman connectors    # all connectors, connected or not
   DISPLAY=:0 xrandr --query
   ```
   In the `xrandr --query` mode list for each output, `*` marks the *current* mode and `+` marks the EDID-*preferred* mode. If the mode you want (e.g. `3840x2160`) is listed but not marked `+`, that's the mismatch this feature fixes. If the mode you want isn't listed at all, the display/cable genuinely can't do it — `lock-resolutions` can't add modes the hardware doesn't report.

3. **Plan the layout.** `lock-resolutions` and `apply_modes` tile every output that has a `DISPLAY_N_MODE` set **left-to-right at `y=0`, in the order the `DISPLAY_N` blocks appear in your config** — e.g. two `3840x2160` outputs become a `7680x2160` canvas with the first at `+0+0` and the second at `+3840+0`. Outputs *without* a `DISPLAY_N_MODE` are left out of this layout entirely (left to normal auto-configuration), so don't mix a forced output and an unforced output that need to sit side-by-side — give both a `DISPLAY_N_MODE` if their relative position matters.

4. **Make sure you can recover if something goes wrong after reboot.** `lock-resolutions` backs up `/etc/X11/xorg.conf` automatically (to `/etc/X11/xorg.conf.bak.<timestamp>`), but a bad `xorg.conf` can still leave you with a black screen or failure to start X. Make sure you have either:
   - physical/console access to the machine, or
   - SSH access so you can restore the backup and reboot remotely:
     ```bash
     sudo cp /etc/X11/xorg.conf.bak.<timestamp> /etc/X11/xorg.conf
     sudo reboot
     ```

#### Configuring `DISPLAY_N_MODE`

Add an optional `DISPLAY_N_MODE=WIDTHxHEIGHT` line to any display block in `chrome-displays.conf`:

```ini
DISPLAY_1_OUTPUT=DP-1
DISPLAY_1_URL=https://example.com
DISPLAY_1_PROFILE=chrome-kiosk-1
DISPLAY_1_AUDIO_SINK=alsa_output.pci-0000_01_00.1.pro-output-3
DISPLAY_1_MODE=3840x2160

DISPLAY_2_OUTPUT=DP-3
DISPLAY_2_URL=https://example2.com
DISPLAY_2_PROFILE=chrome-kiosk-2
DISPLAY_2_AUDIO_SINK=alsa_output.pci-0000_01_00.1.pro-output-7
DISPLAY_2_MODE=3840x2160
```

Rules:
- **Format** is `WIDTHxHEIGHT` (e.g. `3840x2160`, `1920x1080`) — no refresh rate, no quotes.
- **Optional per display** — omit it for any output whose EDID-preferred mode is already correct (e.g. a genuine 1080p monitor).
- The **mode must be one xrandr already lists** for that output (check with `DISPLAY=:0 xrandr --query`); `lock-resolutions`/`apply_modes` can't invent unsupported modes.
- Position is **not configurable** — it's derived automatically from tiling order (see step 3 above). If you need a different arrangement (e.g. stacked instead of side-by-side), that's not currently supported by this command.

#### Running it

```bash
chromeman lock-resolutions
```

This prints the computed layout (per-display mode + the resulting `metamodes`/`Virtual` strings) and asks for confirmation before touching anything:

```
[INFO]  Computed layout (tiled left-to-right in config order):
    Display 1: DP-1 → 3840x2160
    Display 2: DP-3 → 3840x2160

    metamodes: DP-1: 3840x2160 +0+0, DP-3: 3840x2160 +3840+0
    virtual:   7680x2160

[WARN]  This will modify /etc/X11/xorg.conf (sudo required) and needs a reboot to take effect.
  Continue? [y/N]
```

Type `y` to proceed. It will prompt for your `sudo` password, back up the existing `xorg.conf`, and write the new `metamodes`/`Virtual` lines into the `Screen` section. Then:

```bash
sudo reboot
```

#### Verifying it worked

After reboot:

```bash
DISPLAY=:0 xrandr --query | head -3
```

`current` should now be at least as large as the `virtual` size printed by `lock-resolutions` (e.g. `current 7680 x 2160`). If each output is still showing its old/EDID-preferred mode at this point, that's expected — `chromeman start`/`watch` apply the actual per-output modes next (see below). Run:

```bash
chromeman restart
DISPLAY=:0 xrandr --query | head -6
```

and confirm each configured output now shows the `DISPLAY_N_MODE` resolution at the expected `+X+0` position.

#### Ongoing behavior

Once `lock-resolutions` has run and you've rebooted, **no further manual steps are needed**. Every `chromeman start`, `chromeman restart`, and watchdog relaunch automatically re-runs `xrandr` with your `DISPLAY_N_MODE` values (the `apply_modes` step), so the resolutions self-heal even after GNOME resets them on login.

#### Changing the layout later

If you add, remove, or change a `DISPLAY_N_MODE` (or add a new display with one):

```bash
chromeman lock-resolutions   # recompute and rewrite metamodes/Virtual
sudo reboot
chromeman restart
```

#### Reverting entirely

To remove the forced layout and go back to X's default auto-configuration:

```bash
sudo cp /etc/X11/xorg.conf.bak.<timestamp> /etc/X11/xorg.conf   # pick the backup from before your first lock-resolutions run
sudo reboot
```

Also remove any `DISPLAY_N_MODE` lines from `chrome-displays.conf` so `apply_modes` stops trying to re-apply them.

#### Troubleshooting

- **`BadMatch (RRSetScreenSize)` when `apply_modes` runs**: the `Virtual` size in `xorg.conf` is too small for your configured modes — re-run `chromeman lock-resolutions` (it recomputes `Virtual` from your current config) and reboot.
- **Mode not in `xrandr --query`'s list for that output**: the cable/converter/monitor doesn't support it — `lock-resolutions` can't fix this; try a different mode or a different cable/converter.
- **Black screen / X fails to start after reboot**: boot to a recovery shell (or SSH in) and restore the `xorg.conf.bak.<timestamp>` backup, then `sudo reboot`.

---

## Audio Routing

Each display can optionally have its own `DISPLAY_N_AUDIO_SINK`, so that Chrome window's audio plays only out of the speakers/audio device connected to that monitor's output. This is set via Chrome's `PULSE_SINK` environment variable, applied per-launch — no global PulseAudio config changes needed.

### Finding sink names

```bash
chromeman audio-sinks
```

This runs `pactl list short sinks` and shows the sink name to use for `DISPLAY_N_AUDIO_SINK`.

### How NVIDIA multi-output audio usually looks

A single NVIDIA GPU with multiple DisplayPort outputs typically exposes **one PCI audio device** with **multiple ports** (one per DP output), e.g.:

```
alsa_output.pci-0000_01_00.1.hdmi-stereo
alsa_output.pci-0000_01_00.1.hdmi-stereo-extra1
alsa_output.pci-0000_01_00.1.hdmi-stereo-extra2
```

Each of these is a separate **sink**, and each corresponds to a different physical DP output. Assign the sink that matches each monitor's output to that display's `DISPLAY_N_AUDIO_SINK`.

### Matching a sink to a specific monitor

If it's not obvious which `extraN` sink maps to which `DP-N` output, test one at a time:

```bash
# Play a test tone on a specific sink and listen for which monitor's speakers play it
paplay --device=alsa_output.pci-0000_01_00.1.hdmi-stereo-extra1 /usr/share/sounds/alsa/Front_Center.wav
```

Repeat for each sink until you've matched all of them to their monitors, then fill in `DISPLAY_N_AUDIO_SINK` accordingly.

### If your hardware only exposes one combined sink

Some setups expose all DP audio outputs as **ports on a single sink** rather than separate sinks — in that case only one port can be "active" at a time, and `PULSE_SINK` alone won't separate the audio per window. If `chromeman audio-sinks` shows only one sink but `pactl list sinks` shows multiple ports under it, you'll need to create a dedicated virtual sink per port:

```bash
# Find the ALSA hw device for each port
pactl list sinks | grep -A5 "Ports:"

# Create a separate sink bound to each hardware output (repeat per port)
pactl load-module module-alsa-sink device=hw:1,3 sink_name=display1_audio
pactl load-module module-alsa-sink device=hw:1,7 sink_name=display2_audio
```

Then use `display1_audio`, `display2_audio`, etc. as your `DISPLAY_N_AUDIO_SINK` values. To make these persist across reboots, add the `load-module` lines to `/etc/pulse/default.pa` (or the equivalent PipeWire/WirePlumber config on newer Ubuntu).

Leave `DISPLAY_N_AUDIO_SINK` blank/unset for any display that should just use the system default audio output.

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
| `outputs` | List detected monitor outputs (via `xrandr`) |
| `connectors` | List all video connectors, connected or not |
| `audio-sinks` | List audio sinks for per-display audio routing |
| `lock-resolutions` | Pin `DISPLAY_N_MODE` resolutions in `xorg.conf` (sudo, needs reboot) |
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

### Windows land on the wrong monitor

First check for output-mismatch warnings:

```bash
chromeman log
chromeman outputs
```

If a configured `DISPLAY_N_OUTPUT` isn't in the `chromeman outputs` list, a cable was likely moved to a different GPU port, or the monitor was off when X started. Update the config to match, or move the cable back. See [Monitor Outputs](#monitor-outputs).

If all configured outputs are detected but placement still looks wrong, this is almost always a Wayland issue. Check:

```bash
echo $XDG_SESSION_TYPE
```

If it says `wayland`, log out and select **"Ubuntu on Xorg"** at the login screen. `wmctrl` does not support Wayland window placement.

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

# List all windows and their position/geometry
wmctrl -lG

# List detected monitors
chromeman outputs

# Check systemd service status
systemctl --user status chromeman
systemctl --user status chromeman-http
```

---

## Wayland

`wmctrl` — which chromeman uses to position windows on specific monitors — does not work under Wayland. The script will launch Chrome but cannot guarantee it lands on the correct physical display.

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
