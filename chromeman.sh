#!/bin/bash
# =============================================================================
# chromeman — Chrome Kiosk Display Manager
# =============================================================================
# Manages fullscreen Chrome windows pinned to specific physical monitors.
#
# USAGE:
#   chromeman [COMMAND] [OPTIONS]
#
# COMMANDS:
#   start               Launch all displays and start the watchdog
#   stop                Stop watchdog and close all Chrome instances
#   restart             stop + start
#   status              Show current state of all displays and watchdog
#   watch               Run the watchdog in the foreground (used internally)
#   outputs             List detected monitor outputs (via xrandr)
#   connectors          List all video connectors, connected or not
#   audio-sinks         List audio sinks for per-display audio routing
#   lock-resolutions    Pin DISPLAY_N_MODE resolutions in xorg.conf (sudo, needs reboot)
#   install             Install as a systemd user service (auto-start on login)
#   uninstall           Remove the systemd user service
#   log                 Tail the watchdog log
#
# OPTIONS:
#   -c, --config FILE   Path to config file (default: ~/chrome-manager/chrome-displays.conf)
#   -i, --interval SEC  Watchdog check interval in seconds (default: 600)
#   -d, --display N     Target a single display by number (used with stop/status/restart)
#   -h, --help          Show this help message
#   -v, --version       Show version
#
# EXAMPLES:
#   chromeman outputs
#   chromeman start
#   chromeman start --config /etc/chrome-displays.conf
#   chromeman stop
#   chromeman stop --display 2          # close only display 2
#   chromeman restart --display 3       # relaunch only display 3
#   chromeman status
#   chromeman watch --interval 300      # watchdog with 5-minute interval
#   chromeman install
#   chromeman log
# =============================================================================

VERSION="1.5.6"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
DEFAULT_CONFIG_DIR="$HOME/chrome-manager"
DEFAULT_CONFIG="$DEFAULT_CONFIG_DIR/chrome-displays.conf"
DEFAULT_INTERVAL=600
DEFAULT_HTTP_PORT=7070
LOG_FILE="$DEFAULT_CONFIG_DIR/chromeman.log"
PID_FILE="$DEFAULT_CONFIG_DIR/watchdog.pid"
HTTP_PID_FILE="$DEFAULT_CONFIG_DIR/http-server.pid"
PAUSED_DIR="$DEFAULT_CONFIG_DIR/paused"   # lock files live here: paused/<profile>
SERVICE_NAME="chromeman"
HTTP_SERVICE_NAME="chromeman-http"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
HTTP_SERVICE_FILE="$HOME/.config/systemd/user/${HTTP_SERVICE_NAME}.service"

export DISPLAY="${DISPLAY:-:0}"

# =============================================================================
# Helpers
# =============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m  $*"; }
die()   { error "$*"; exit 1; }

require_wmctrl() {
    command -v wmctrl &>/dev/null || die "wmctrl is not installed. Run: sudo apt install wmctrl"
}

require_xrandr() {
    command -v xrandr &>/dev/null || die "xrandr is not installed. Run: sudo apt install x11-xserver-utils"
}

require_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE
  Create one with: chromeman init"
}

# =============================================================================
# Monitor geometry — maps an xrandr output name to "X Y W H"
# =============================================================================

get_monitor_geometry() {
    local output="$1"
    local line geom
    line=$(xrandr --listmonitors | grep -E "[[:space:]]${output}$")
    [[ -n "$line" ]] || return 1

    # Field 3 looks like: 3840/1020x2160/570+5760+0  (strip the /<mm> parts)
    geom=$(echo "$line" | awk '{print $3}' | sed -E 's#/[0-9]+##g')

    local w h x y
    w=$(echo "$geom" | grep -oP '^[0-9]+')
    h=$(echo "$geom" | grep -oP 'x\K[0-9]+')
    x=$(echo "$geom" | grep -oP '\+\K[0-9]+(?=\+)')
    y=$(echo "$geom" | grep -oP '\+[0-9]+\+\K[0-9]+')

    [[ -n "$w" && -n "$h" && -n "$x" && -n "$y" ]] || return 1
    echo "$x $y $w $h"
}

# =============================================================================
# Config parsing — populates OUTPUTS[], URLS[], PROFILES[]
# =============================================================================

load_config() {
    OUTPUTS=()
    URLS=()
    PROFILES=()
    AUDIO_SINKS=()
    MODES=()

    require_config

    local max_n
    max_n=$(grep -oP 'DISPLAY_\K[0-9]+' "$CONFIG_FILE" | sort -n | tail -1)
    [[ -n "$max_n" ]] || die "No DISPLAY_* entries found in $CONFIG_FILE"

    for n in $(seq 1 "$max_n"); do
        local out url prof sink mode
        out=$(grep  "^DISPLAY_${n}_OUTPUT="     "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        url=$(grep  "^DISPLAY_${n}_URL="        "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        prof=$(grep "^DISPLAY_${n}_PROFILE="    "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        sink=$(grep "^DISPLAY_${n}_AUDIO_SINK=" "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        mode=$(grep "^DISPLAY_${n}_MODE="       "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')

        if [[ -n "$out" && -n "$url" && -n "$prof" ]]; then
            OUTPUTS+=("$out")
            URLS+=("$url")
            PROFILES+=("$prof")
            AUDIO_SINKS+=("$sink")
            MODES+=("$mode")
        fi
    done

    [[ ${#OUTPUTS[@]} -gt 0 ]] || die "No valid display entries found in $CONFIG_FILE"
}

# =============================================================================
# Validate that every configured output is currently connected
# =============================================================================

validate_outputs() {
    local connected
    connected=$(xrandr --listmonitors | awk 'NR>1 {print $NF}')

    local missing=()
    local out
    for out in "${OUTPUTS[@]}"; do
        if ! grep -qxF "$out" <<< "$connected"; then
            missing+=("$out")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "[WARN] Configured output(s) not currently detected: ${missing[*]}"
        log "[WARN] Connected outputs right now: $(echo "$connected" | tr '\n' ' ')"
        log "[WARN] If a monitor was moved to a different port or is powered off, displays may launch on the wrong screen or without placement."
        log "[WARN] Run 'chromeman outputs' to see current monitor names."
    fi
}

# =============================================================================
# Apply DISPLAY_N_MODE resolutions via xrandr (tiled left-to-right at y=0,
# same layout as `chromeman lock-resolutions`). Self-heals the case where
# GNOME/mutter reset outputs to their EDID-preferred mode on login/reboot.
# Requires the xorg.conf Virtual canvas from `chromeman lock-resolutions` to
# be large enough, or this will fail with a RandR BadMatch.
# =============================================================================

apply_modes() {
    local -a parts=()
    local total_width=0
    local i

    for i in "${!OUTPUTS[@]}"; do
        local mode="${MODES[$i]}"
        [[ -n "$mode" ]] || continue
        local w="${mode%x*}"
        parts+=(--output "${OUTPUTS[$i]}" --mode "$mode" --pos "${total_width}x0")
        total_width=$(( total_width + w ))
    done

    [[ ${#parts[@]} -gt 0 ]] || return 0

    local err
    if err=$(xrandr "${parts[@]}" 2>&1); then
        log "Applied configured resolutions: xrandr ${parts[*]}"
    else
        log "[WARN] Failed to apply configured resolutions: $err"
        log "[WARN] Run 'chromeman lock-resolutions' and reboot if this is a virtual-screen-size issue."
    fi
}

# =============================================================================
# Chrome process helpers
# =============================================================================

profile_dir() { echo "$HOME/.config/$1"; }

is_running() {
    pgrep -f "user-data-dir=$(profile_dir "$1")" > /dev/null 2>&1
}

get_pids() {
    pgrep -f "user-data-dir=$(profile_dir "$1")"
}

# Pause lock file helpers — a paused display is skipped by the watchdog
is_paused() {
    [[ -f "$PAUSED_DIR/$1" ]]
}

pause_display() {
    mkdir -p "$PAUSED_DIR"
    touch "$PAUSED_DIR/$1"
}

resume_display() {
    rm -f "$PAUSED_DIR/$1"
}

# =============================================================================
# Launch a single Chrome instance pinned to a physical monitor output
# =============================================================================

launch_one() {
    local output="$1"
    local url="$2"
    local profile_name="$3"
    local dn="$4"
    local audio_sink="$5"
    local prof_dir
    prof_dir=$(profile_dir "$profile_name")
    local tag="[Display $dn]"

    local geom="" x y w h
    if geom=$(get_monitor_geometry "$output"); then
        read -r x y w h <<< "$geom"
    else
        warn "$tag Output '$output' not found via xrandr — launching without placement."
    fi

    log "$tag Launching → $url (output: $output)"

    local -a chrome_args=(
        --new-window
        --kiosk
        --start-fullscreen
        --autoplay-policy=no-user-gesture-required
        --user-data-dir="$prof_dir"
        --no-default-browser-check
        --disable-session-crashed-bubble
        --disable-infobars
        --disable-sync
        --disable-background-networking
    )
    [[ -n "$geom" ]] && chrome_args+=(--window-position="${x},${y}" --window-size="${w},${h}")
    chrome_args+=("$url")

    if [[ -n "$audio_sink" ]]; then
        log "$tag Audio → $audio_sink"
        PULSE_SINK="$audio_sink" google-chrome "${chrome_args[@]}" >/dev/null 2>&1 &
    else
        google-chrome "${chrome_args[@]}" >/dev/null 2>&1 &
    fi

    local chrome_pid=$!
    log "$tag Chrome started (PID $chrome_pid)"

    # Wait for window then pin it to the correct monitor
    local attempt
    for attempt in $(seq 1 20); do
        sleep 0.5
        local win_id
        win_id=$(wmctrl -lp | awk -v pid="$chrome_pid" '$3 == pid { print $1; exit }')

        # Fallback: match by profile dir in cmdline (Snap/Flatpak wrapping)
        if [[ -z "$win_id" ]]; then
            local fallback_pids
            fallback_pids=$(pgrep -f "user-data-dir=$prof_dir" | tr '\n' '|' | sed 's/|$//')
            if [[ -n "$fallback_pids" ]]; then
                win_id=$(wmctrl -lp | grep -E "($fallback_pids)" | head -1 | awk '{print $1}')
            fi
        fi

        if [[ -n "$win_id" ]]; then
            log "$tag Window $win_id found."
            if [[ -n "$geom" ]]; then
                log "$tag Moving to $output (${w}x${h}+${x}+${y})"
                wmctrl -i -r "$win_id" -b remove,fullscreen
                wmctrl -i -r "$win_id" -e "0,$x,$y,$w,$h"
                sleep 0.3
            fi
            wmctrl -i -r "$win_id" -b add,fullscreen
            log "$tag Ready."
            return 0
        fi
    done

    log "$tag [WARN] Window not found after 10s — Chrome may still be loading."
    return 0
}

# =============================================================================
# COMMAND: start
# =============================================================================

cmd_start() {
    require_wmctrl
    require_xrandr
    load_config
    validate_outputs
    apply_modes

    info "Starting ${#OUTPUTS[@]} display(s)..."
    mkdir -p "$DEFAULT_CONFIG_DIR"

    local count=${#OUTPUTS[@]}
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        # Skip if a specific display was requested and this isn't it
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != "$dn" && \
              "$TARGET_DISPLAY" != "${OUTPUTS[$i]}" ]]; then
            continue
        fi

        if is_running "${PROFILES[$i]}"; then
            ok "Display $dn (${OUTPUTS[$i]}) already running — skipping."
        elif is_paused "${PROFILES[$i]}"; then
            if [[ -n "$TARGET_DISPLAY" ]]; then
                # Explicit single-display start clears the pause lock
                resume_display "${PROFILES[$i]}"
                info "Display $dn (${OUTPUTS[$i]}) unpaused."
                local url="${OVERRIDE_URL:-${URLS[$i]}}"
                launch_one "${OUTPUTS[$i]}" "$url" "${PROFILES[$i]}" "$dn" "${AUDIO_SINKS[$i]}"
                sleep 1
            else
                warn "Display $dn (${OUTPUTS[$i]}) is paused — skipping (run: chromeman resume -d $dn)."
            fi
        else
            local url="${OVERRIDE_URL:-${URLS[$i]}}"
            launch_one "${OUTPUTS[$i]}" "$url" "${PROFILES[$i]}" "$dn" "${AUDIO_SINKS[$i]}"
            sleep 1  # stagger to avoid WM race conditions
        fi
    done

    # Start watchdog in background unless a single display was targeted
    if [[ -z "$TARGET_DISPLAY" ]]; then
        if watchdog_running; then
            ok "Watchdog already running (PID $(cat "$PID_FILE"))."
        else
            info "Starting watchdog (interval: ${INTERVAL}s)..."
            "$SCRIPT_PATH" watch --config "$CONFIG_FILE" --interval "$INTERVAL" \
                > /dev/null 2>> "$LOG_FILE" &
            echo $! > "$PID_FILE"
            ok "Watchdog started (PID $!)."
        fi
    fi

    ok "Done."
}

# =============================================================================
# COMMAND: stop
# =============================================================================

cmd_stop() {
    load_config

    # Stop watchdog first (unless targeting a single display)
    if [[ -z "$TARGET_DISPLAY" ]]; then
        stop_watchdog
    fi

    local count=${#OUTPUTS[@]}
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != "$dn" && \
              "$TARGET_DISPLAY" != "${OUTPUTS[$i]}" ]]; then
            continue
        fi

        local prof="${PROFILES[$i]}"
        local out="${OUTPUTS[$i]}"

        # --no-restart: write a pause lock so the watchdog won't relaunch this display
        if [[ "$NO_RESTART" == "1" ]]; then
            pause_display "$prof"
            info "Display $dn ($out) marked as paused (watchdog will not relaunch it)."
        fi

        local pids
        pids=$(get_pids "$prof")

        if [[ -z "$pids" ]]; then
            info "Display $dn ($out) not running."
        else
            info "Closing display $dn ($out) (PIDs: $(echo "$pids" | tr '\n' ' '))..."
            kill $pids 2>/dev/null
        fi
    done

    # Wait then force-kill stragglers
    sleep 3
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != "$dn" && \
              "$TARGET_DISPLAY" != "${OUTPUTS[$i]}" ]]; then
            continue
        fi
        local remaining
        remaining=$(get_pids "${PROFILES[$i]}")
        if [[ -n "$remaining" ]]; then
            warn "Force-killing display $dn (${OUTPUTS[$i]})..."
            kill -9 $remaining 2>/dev/null
        fi
    done

    # Full stop (no --display) clears all pause locks
    if [[ -z "$TARGET_DISPLAY" ]]; then
        rm -rf "$PAUSED_DIR"
    fi

    ok "Done."
}

# =============================================================================
# COMMAND: restart
# =============================================================================

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

# =============================================================================
# COMMAND: status
# =============================================================================

cmd_status() {
    load_config

    echo ""
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │              chromeman — display status             │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo ""

    local count=${#OUTPUTS[@]}
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        local out="${OUTPUTS[$i]}"
        local url="${URLS[$i]}"
        local prof="${PROFILES[$i]}"
        local pids
        pids=$(get_pids "$prof")
        local label="$dn ($out)"

        if [[ -n "$pids" ]]; then
            printf "  \033[1;32m●\033[0m  Display %-10s  %-40s  PIDs: %s\n" "$label" "$url" "$(echo "$pids" | tr '\n' ' ')"
        elif is_paused "$prof"; then
            printf "  \033[1;33m⏸\033[0m  Display %-10s  %-40s  paused\n" "$label" "$url"
        else
            printf "  \033[1;31m○\033[0m  Display %-10s  %-40s  not running\n" "$label" "$url"
        fi
    done

    echo ""

    if watchdog_running; then
        printf "  \033[1;32m●\033[0m  Watchdog running  (PID %s, interval: %ss)\n" \
            "$(cat "$PID_FILE")" "$INTERVAL"
    else
        printf "  \033[1;31m○\033[0m  Watchdog not running\n"
    fi

    # Systemd service status
    if systemctl --user is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        printf "  \033[1;32m●\033[0m  systemd service active\n"
    fi

    echo ""
    echo "  Config:   $CONFIG_FILE"
    echo "  Log:      $LOG_FILE"
    echo ""
}

# =============================================================================
# COMMAND: status-json — machine-readable status (used by http-server)
# =============================================================================

cmd_status_json() {
    load_config

    local json='{"displays":['
    local count=${#OUTPUTS[@]}
    local i
    for (( i=0; i<count; i++ )); do
        local state="stopped"
        is_paused  "${PROFILES[$i]}" && state="paused"
        is_running "${PROFILES[$i]}" && state="running"
        [[ $i -gt 0 ]] && json+=","
        json+="{\"display\":$(( i+1 )),\"output\":\"${OUTPUTS[$i]}\",\"url\":\"${URLS[$i]}\",\"state\":\"$state\"}"
    done
    json+="],"
    watchdog_running && json+='"watchdog":"running"' || json+='"watchdog":"stopped"'
    json+="}"

    echo "$json"
}

# =============================================================================
# COMMAND: outputs — list detected monitor outputs (via xrandr)
# =============================================================================

cmd_outputs() {
    require_xrandr
    info "Detected monitor outputs:"
    echo ""
    xrandr --listmonitors
    echo ""
    info "Use the name in the rightmost column (e.g. DP-7) as DISPLAY_N_OUTPUT in your config."
}

# =============================================================================
# COMMAND: connectors — list all video connectors, connected or not
# =============================================================================

cmd_connectors() {
    require_xrandr
    info "All display connectors:"
    echo ""
    xrandr --query | grep -E "^[A-Za-z0-9-]+ (connected|disconnected)"
    echo ""
    info "Only 'connected' outputs can be used as DISPLAY_N_OUTPUT."
}

# =============================================================================
# COMMAND: audio-sinks — list PulseAudio/PipeWire sinks for per-display audio
# =============================================================================

cmd_audio_sinks() {
    command -v pactl &>/dev/null || die "pactl not found. Run: sudo apt install pulseaudio-utils"
    info "Available audio sinks:"
    echo ""
    pactl list short sinks
    echo ""
    info "Use the sink name (2nd column) as DISPLAY_N_AUDIO_SINK in your config."
    echo ""
    info "If a sink exposes multiple ports (one per DP/HDMI output), list ports with:"
    echo "       pactl list sinks | less"
    info "Each port may need its own sink — see the Audio Routing section of the README."
}

# =============================================================================
# COMMAND: lock-resolutions — pin DISPLAY_N_MODE resolutions in xorg.conf
# =============================================================================
# Writes an "Option metamodes" + "Virtual" canvas into /etc/X11/xorg.conf so
# the configured outputs always come up at the resolution you chose, instead
# of falling back to each monitor's EDID-"preferred" mode at every boot or
# hotplug. Outputs are tiled left-to-right at y=0 in config order.

cmd_lock_resolutions() {
    require_xrandr
    load_config

    local xorg_conf="/etc/X11/xorg.conf"
    [[ -f "$xorg_conf" ]] || die "xorg.conf not found at $xorg_conf. Run 'sudo nvidia-xconfig' first to generate one."

    local -a metamode_parts=()
    local total_width=0
    local max_height=0
    local i

    for i in "${!OUTPUTS[@]}"; do
        local out="${OUTPUTS[$i]}"
        local mode="${MODES[$i]}"
        [[ -n "$mode" ]] || continue

        [[ "$mode" =~ ^[0-9]+x[0-9]+$ ]] || die "Invalid DISPLAY_$((i+1))_MODE='$mode' — expected WIDTHxHEIGHT (e.g. 3840x2160)"

        local w="${mode%x*}"
        local h="${mode#*x}"

        metamode_parts+=("${out}: ${mode} +${total_width}+0")
        total_width=$(( total_width + w ))
        (( h > max_height )) && max_height=$h
    done

    [[ ${#metamode_parts[@]} -gt 0 ]] || die "No DISPLAY_N_MODE values set in $CONFIG_FILE — nothing to pin. Add e.g. DISPLAY_1_MODE=3840x2160"

    local metamodes_str
    metamodes_str=$(printf '%s, ' "${metamode_parts[@]}")
    metamodes_str="${metamodes_str%, }"

    info "Computed layout (tiled left-to-right in config order):"
    for i in "${!OUTPUTS[@]}"; do
        [[ -n "${MODES[$i]}" ]] && echo "    Display $((i+1)): ${OUTPUTS[$i]} → ${MODES[$i]}"
    done
    echo ""
    echo "    metamodes: $metamodes_str"
    echo "    virtual:   ${total_width}x${max_height}"
    echo ""
    warn "This will modify $xorg_conf (sudo required) and needs a reboot to take effect."
    read -rp "  Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted. No changes made."; exit 0; }

    local backup="${xorg_conf}.bak.$(date +%Y%m%d-%H%M%S)"
    sudo cp "$xorg_conf" "$backup" || die "Failed to back up $xorg_conf"
    ok "Backed up current config to $backup"

    awk -v meta="$metamodes_str" -v virt="$total_width $max_height" '
        /^[[:space:]]*Option[[:space:]]+"metamodes"/ { next }
        /^[[:space:]]*Virtual[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ { next }
        /DefaultDepth/ {
            print
            print "    Option         \"metamodes\" \"" meta "\""
            next
        }
        /^[[:space:]]*Depth[[:space:]]+[0-9]+/ {
            print
            print "        Virtual     " virt
            next
        }
        { print }
    ' "$xorg_conf" | sudo tee "${xorg_conf}.new" > /dev/null && sudo mv "${xorg_conf}.new" "$xorg_conf"

    ok "Updated $xorg_conf"
    info "Reboot for this to take effect: sudo reboot"
}

# =============================================================================
# COMMAND: watch (watchdog loop — called internally, or run directly)
# =============================================================================

cmd_watch() {
    require_wmctrl
    require_xrandr
    load_config
    mkdir -p "$DEFAULT_CONFIG_DIR"

    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT

    log "========================================"
    log "chromeman watchdog started"
    log "Config:   $CONFIG_FILE"
    log "Interval: ${INTERVAL}s"
    log "========================================"

    validate_outputs
    apply_modes

    while true; do
        local count=${#OUTPUTS[@]}
        for (( i=0; i<count; i++ )); do
            local dn=$(( i+1 ))
            local out="${OUTPUTS[$i]}"
            local url="${URLS[$i]}"
            local prof="${PROFILES[$i]}"

            if is_paused "$prof"; then
                log "[Display $dn] ⏸ Paused — skipping"
            elif is_running "$prof"; then
                log "[Display $dn] ✓ Running"
            else
                log "[Display $dn] ✗ Not running — relaunching → $url"
                launch_one "$out" "$url" "$prof" "$dn" "${AUDIO_SINKS[$i]}"
                sleep 2
            fi
        done

        log "Next check in ${INTERVAL}s..."
        sleep "$INTERVAL"
    done
}

# =============================================================================
# COMMAND: pause — stop a display and prevent watchdog from relaunching it
# =============================================================================

cmd_pause() {
    load_config

    [[ -n "$TARGET_DISPLAY" ]] || die "pause requires -d <display>. Example: chromeman pause -d 2"

    local count=${#OUTPUTS[@]}
    local matched=0
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        if [[ "$TARGET_DISPLAY" != "$dn" && "$TARGET_DISPLAY" != "${OUTPUTS[$i]}" ]]; then
            continue
        fi
        matched=1
        local prof="${PROFILES[$i]}"
        local out="${OUTPUTS[$i]}"

        pause_display "$prof"
        info "Display $dn ($out) paused — watchdog will no longer relaunch it."

        local pids
        pids=$(get_pids "$prof")
        if [[ -n "$pids" ]]; then
            info "Closing display $dn ($out) (PIDs: $(echo "$pids" | tr '\n' ' '))..."
            kill $pids 2>/dev/null
            sleep 3
            pids=$(get_pids "$prof")
            [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
        else
            info "Display $dn ($out) was not running."
        fi
        ok "Display $dn ($out) paused."
    done

    [[ $matched -eq 1 ]] || die "No display matching '$TARGET_DISPLAY' found in config."
}

# =============================================================================
# COMMAND: resume — clear pause lock and relaunch the display
# =============================================================================

cmd_resume() {
    require_wmctrl
    require_xrandr
    load_config

    [[ -n "$TARGET_DISPLAY" ]] || die "resume requires -d <display>. Example: chromeman resume -d 2"

    local count=${#OUTPUTS[@]}
    local matched=0
    for (( i=0; i<count; i++ )); do
        local dn=$(( i+1 ))
        if [[ "$TARGET_DISPLAY" != "$dn" && "$TARGET_DISPLAY" != "${OUTPUTS[$i]}" ]]; then
            continue
        fi
        matched=1
        local prof="${PROFILES[$i]}"
        local out="${OUTPUTS[$i]}"
        local url="${URLS[$i]}"

        if ! is_paused "$prof"; then
            warn "Display $dn ($out) is not paused."
        else
            resume_display "$prof"
            ok "Display $dn ($out) unpaused."
        fi

        if is_running "$prof"; then
            ok "Display $dn ($out) already running."
        else
            local url="${OVERRIDE_URL:-$url}"
            info "Launching display $dn ($out) → $url"
            launch_one "$out" "$url" "$prof" "$dn" "${AUDIO_SINKS[$i]}"
        fi
    done

    [[ $matched -eq 1 ]] || die "No display matching '$TARGET_DISPLAY' found in config."
}

# =============================================================================
# COMMAND: install (systemd user service)
# =============================================================================

cmd_install() {
    mkdir -p "$(dirname "$SERVICE_FILE")"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Chrome Kiosk Display Manager (chromeman)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} watch --config ${CONFIG_FILE} --interval ${INTERVAL}
ExecStop=${SCRIPT_PATH} stop --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
Environment=DISPLAY=:0
PassEnvironment=DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    ok "Service installed and enabled: $SERVICE_FILE"
    info "It will auto-start on next login. To start it now:"
    echo "       systemctl --user start $SERVICE_NAME"
}

# =============================================================================
# COMMAND: uninstall
# =============================================================================

cmd_uninstall() {
    systemctl --user stop    "$SERVICE_NAME" 2>/dev/null
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    ok "Service removed."
}

# =============================================================================
# COMMAND: log
# =============================================================================

cmd_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        info "No log file yet: $LOG_FILE"
        exit 0
    fi
    exec tail -f "$LOG_FILE"
}

# =============================================================================
# COMMAND: init (create a default config file)
# =============================================================================

cmd_init() {
    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Config already exists: $CONFIG_FILE"
        read -rp "  Overwrite? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
# chromeman display config
# One block per display, numbered from 1.
#
# DISPLAY_N_OUTPUT      = xrandr output name for the physical monitor
#                         (run `chromeman outputs` to list them, e.g. DP-7)
# DISPLAY_N_URL         = page to load in kiosk mode
# DISPLAY_N_PROFILE     = unique Chrome profile name (no spaces)
# DISPLAY_N_AUDIO_SINK  = (optional) PulseAudio sink name for this display's audio
#                         (run `chromeman audio-sinks` to list them)
# DISPLAY_N_MODE        = (optional) WIDTHxHEIGHT to force via `chromeman lock-resolutions`
#                         (use this if a monitor's EDID-preferred mode isn't the one you want)

DISPLAY_1_OUTPUT=DP-7
DISPLAY_1_URL=https://www.example.com
DISPLAY_1_PROFILE=chrome-kiosk-1
# DISPLAY_1_AUDIO_SINK=alsa_output.pci-0000_01_00.1.hdmi-stereo
# DISPLAY_1_MODE=3840x2160

DISPLAY_2_OUTPUT=DP-1
DISPLAY_2_URL=https://www.example2.com
DISPLAY_2_PROFILE=chrome-kiosk-2
# DISPLAY_2_AUDIO_SINK=alsa_output.pci-0000_01_00.1.hdmi-stereo-extra1
# DISPLAY_2_MODE=3840x2160

DISPLAY_3_OUTPUT=DP-3
DISPLAY_3_URL=https://www.example3.com
DISPLAY_3_PROFILE=chrome-kiosk-3
# DISPLAY_3_AUDIO_SINK=alsa_output.pci-0000_01_00.1.hdmi-stereo-extra2
# DISPLAY_3_MODE=3840x2160
EOF
    ok "Config created: $CONFIG_FILE"
    info "Run 'chromeman outputs' to see your monitor names, then edit the config."
    info "Then run: chromeman start"
}

# =============================================================================
# COMMAND: http-server
# Small HTTP server (embedded Python) that Companion hits to trigger
# chromeman actions.
#
# Supported endpoints (GET):
#   /restart              restart all displays
#   /restart?d=2          restart display 2
#   /restart?d=2&url=...  restart display 2 with a URL override (URL-encoded)
#   /start                start all displays
#   /start?d=2
#   /stop                 stop all displays
#   /stop?d=2
#   /pause?d=2
#   /resume?d=2
#   /status               returns JSON status of all displays
# =============================================================================

cmd_http_server() {
    local port="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    mkdir -p "$DEFAULT_CONFIG_DIR"

    if [[ -f "$HTTP_PID_FILE" ]] && kill -0 "$(cat "$HTTP_PID_FILE")" 2>/dev/null; then
        warn "HTTP server already running on port $port (PID $(cat "$HTTP_PID_FILE"))."
        exit 0
    fi

    command -v python3 &>/dev/null || die "python3 not found."

    log "[HTTP] chromeman HTTP server listening on port $port"
    log "[HTTP] Endpoints: GET /restart /start /stop /pause /resume /status"
    log "[HTTP] Params:    ?d=<display_number>  &url=<url-encoded-url>"

    CHROMEMAN_PORT="$port" CHROMEMAN_SCRIPT="$SCRIPT_PATH" CHROMEMAN_CONFIG="$CONFIG_FILE" \
        CHROMEMAN_LOG="$LOG_FILE" CHROMEMAN_DISPLAY="${DISPLAY:-:0}" \
        python3 - <<'PYEOF' &
import os, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT    = int(os.environ["CHROMEMAN_PORT"])
SCRIPT  = os.environ["CHROMEMAN_SCRIPT"]
CONFIG  = os.environ["CHROMEMAN_CONFIG"]
LOGFILE = os.environ["CHROMEMAN_LOG"]
DISPLAY = os.environ.get("CHROMEMAN_DISPLAY", ":0")

ACTIONS = {
    "/restart": "restart",
    "/start":   "start",
    "/stop":    "stop",
    "/pause":   "pause",
    "/resume":  "resume",
}

def log(msg):
    line = "[%s] [HTTP] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOGFILE, "a") as f:
            f.write(line)
    except OSError:
        pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _respond(self, code, body, content_type="text/plain"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        d = (qs.get("d") or [None])[0]
        url = (qs.get("url") or [None])[0]

        if path == "/favicon.ico":
            self._respond(204, "")
            return

        if path == "/status":
            try:
                out = subprocess.run(
                    [SCRIPT, "status-json", "--config", CONFIG],
                    capture_output=True, text=True, timeout=10, check=True)
                self._respond(200, out.stdout.strip(), "application/json")
            except Exception as exc:
                self._respond(500, "ERROR: %s" % exc)
                log("%s %s -> 500 %s" % (self.command, self.path, exc))
            return

        action = ACTIONS.get(path)
        if action is None:
            self._respond(404, "ERROR: unknown endpoint '%s'" % path)
            log("%s %s -> 404 unknown endpoint" % (self.command, self.path))
            return

        if action in ("pause", "resume") and not d:
            self._respond(400, "ERROR: ?d= required")
            return

        if d is not None and not d.isdigit():
            self._respond(400, "ERROR: ?d= must be a number")
            return

        cmd_args = [action]
        if d:
            cmd_args += ["-d", d]
        if url and action in ("restart", "start", "resume"):
            cmd_args += ["-u", url]

        self._respond(200, "OK: chromeman " + " ".join(cmd_args))
        log("%s %s -> chromeman %s" % (self.command, self.path, " ".join(cmd_args)))

        env = dict(os.environ)
        env["DISPLAY"] = DISPLAY
        with open(LOGFILE, "a") as logf:
            subprocess.Popen(
                [SCRIPT] + cmd_args + ["--config", CONFIG],
                stdout=subprocess.DEVNULL, stderr=logf, env=env,
                start_new_session=True)

server = ThreadingHTTPServer(("", PORT), Handler)
server.serve_forever()
PYEOF

    local pypid=$!
    echo "$pypid" > "$HTTP_PID_FILE"

    trap 'kill "$pypid" 2>/dev/null; rm -f "$HTTP_PID_FILE"; log "[HTTP] Server stopped."; exit 0' EXIT INT TERM

    wait "$pypid"
}

# =============================================================================
# COMMAND: install-http — register HTTP server as a systemd user service
# =============================================================================

cmd_install_http() {
    local port="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    mkdir -p "$(dirname "$HTTP_SERVICE_FILE")"

    cat > "$HTTP_SERVICE_FILE" <<EOF
[Unit]
Description=chromeman HTTP API server (Companion integration)
After=graphical-session.target chromeman.service
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} http-server --port ${port} --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0
PassEnvironment=DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "$HTTP_SERVICE_NAME"
    ok "HTTP service installed: $HTTP_SERVICE_FILE"
    info "Start it now with:"
    echo "       systemctl --user start $HTTP_SERVICE_NAME"
    echo ""
    info "Companion URL format:"
    echo "       http://localhost:${port}/restart?d=2"
    echo "       http://localhost:${port}/restart?d=2&url=https%3A%2F%2Fexample.com"
    echo "       http://localhost:${port}/status"
}

# =============================================================================
# COMMAND: uninstall-http
# =============================================================================

cmd_uninstall_http() {
    systemctl --user stop    "$HTTP_SERVICE_NAME" 2>/dev/null
    systemctl --user disable "$HTTP_SERVICE_NAME" 2>/dev/null
    rm -f "$HTTP_SERVICE_FILE"
    systemctl --user daemon-reload
    ok "HTTP service removed."
}

# =============================================================================
# Watchdog helpers
# =============================================================================

watchdog_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

stop_watchdog() {
    if watchdog_running; then
        info "Stopping watchdog (PID $(cat "$PID_FILE"))..."
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    # Also kill any loose watch processes not tracked by PID file
    pkill -f "chromeman.*watch" 2>/dev/null
    # Systemd service
    if systemctl --user is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Stopping systemd service..."
        systemctl --user stop "${SERVICE_NAME}.service"
    fi
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
    cat <<EOF

  \033[1mchromeman v${VERSION}\033[0m — Chrome Kiosk Display Manager

  \033[1mUSAGE\033[0m
    chromeman <command> [options]

  \033[1mCOMMANDS\033[0m
    start           Launch all displays + start watchdog
    stop            Stop watchdog + close all Chrome instances
    restart         stop then start
    pause           Close one display and prevent watchdog from relaunching it
    resume          Re-enable and relaunch a paused display
    status          Show running state of all displays and watchdog
    watch           Run watchdog in foreground (used internally by start)
    outputs         List detected monitor outputs (via xrandr)
    connectors      List all video connectors, connected or not
    audio-sinks     List audio sinks for per-display audio routing
    lock-resolutions  Pin DISPLAY_N_MODE resolutions in xorg.conf (sudo, needs reboot)
    http-server     Start HTTP API server for Companion integration
    install         Install watchdog as a systemd user service
    install-http    Install HTTP server as a systemd user service
    uninstall       Remove watchdog systemd service
    uninstall-http  Remove HTTP server systemd service
    init            Create a default config file
    log             Tail the watchdog log (Ctrl-C to exit)

  \033[1mOPTIONS\033[0m
    -c, --config FILE     Config file path
                          (default: ~/chrome-manager/chrome-displays.conf)
    -i, --interval SEC    Watchdog check interval in seconds (default: 600)
    -p, --port PORT       HTTP server port (default: 7070)
    -d, --display N       Target a single display number
    -u, --url URL         Override the URL for the targeted display (runtime only)
    -n, --no-restart      With stop -d N: prevent watchdog from relaunching
    -h, --help            Show this help
    -v, --version         Show version

  \033[1mCOMPANION HTTP ENDPOINTS\033[0m  (default port 7070)
    GET /restart                restart all displays
    GET /restart?d=2            restart display 2
    GET /restart?d=2&url=...    restart display 2 with a URL override (URL-encoded)
    GET /start                  start all displays
    GET /start?d=2
    GET /stop                   stop all displays
    GET /stop?d=2
    GET /pause?d=2              pause display 2
    GET /resume?d=2             resume display 2
    GET /status                 returns JSON state of all displays

  \033[1mEXAMPLES\033[0m
    chromeman outputs                           # list monitor names (e.g. DP-7)
    chromeman audio-sinks                       # list audio sinks for per-display audio
    chromeman lock-resolutions                  # pin DISPLAY_N_MODE resolutions in xorg.conf
    chromeman init                              # create default config
    chromeman start                             # launch everything
    chromeman start -d 2 -u https://example.com # launch display 2 with custom URL
    chromeman stop -d 3 --no-restart            # close display 3, watchdog won't relaunch
    chromeman pause -d 2                        # pause display 2
    chromeman resume -d 2                       # resume display 2
    chromeman restart -d 1 -u https://new.com   # bounce display 1 with new URL
    chromeman http-server                       # start HTTP server on port 7070
    chromeman http-server -p 8080               # start on custom port
    chromeman install                           # auto-start watchdog on login
    chromeman install-http                      # auto-start HTTP server on login
    chromeman log                               # tail the log

EOF
}

# =============================================================================
# Argument parsing
# =============================================================================

COMMAND=""
CONFIG_FILE="$DEFAULT_CONFIG"
INTERVAL="$DEFAULT_INTERVAL"
HTTP_PORT="$DEFAULT_HTTP_PORT"
TARGET_DISPLAY=""
NO_RESTART="0"
OVERRIDE_URL=""

# First positional arg is the command
if [[ $# -gt 0 && "$1" != -* ]]; then
    COMMAND="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"; shift 2 ;;
        -i|--interval)
            INTERVAL="$2"; shift 2 ;;
        -d|--display)
            TARGET_DISPLAY="$2"; shift 2 ;;
        -u|--url)
            OVERRIDE_URL="$2"; shift 2 ;;
        -p|--port)
            HTTP_PORT="$2"; shift 2 ;;
        -n|--no-restart)
            NO_RESTART="1"; shift ;;
        -h|--help)
            COMMAND="help"; shift ;;
        -v|--version)
            echo "chromeman v${VERSION}"; exit 0 ;;
        *)
            die "Unknown option: $1. Run 'chromeman --help' for usage." ;;
    esac
done

[[ -z "$COMMAND" ]] && { cmd_help; exit 0; }

case "$COMMAND" in
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart ;;
    pause)          cmd_pause ;;
    resume)         cmd_resume ;;
    status)         cmd_status ;;
    status-json)    cmd_status_json ;;
    watch)          cmd_watch ;;
    outputs)        cmd_outputs ;;
    connectors)     cmd_connectors ;;
    audio-sinks)    cmd_audio_sinks ;;
    lock-resolutions) cmd_lock_resolutions ;;
    http-server)    cmd_http_server ;;
    install)        cmd_install ;;
    install-http)   cmd_install_http ;;
    uninstall)      cmd_uninstall ;;
    uninstall-http) cmd_uninstall_http ;;
    init)           cmd_init ;;
    log)            cmd_log ;;
    help)           cmd_help ;;
    *)              die "Unknown command: $COMMAND. Run 'chromeman --help' for usage." ;;
esac
