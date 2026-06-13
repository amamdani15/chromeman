#!/bin/bash
# =============================================================================
# chromeman — Chrome Kiosk Display Manager
# =============================================================================
# Manages fullscreen Chrome windows across multiple virtual desktops.
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

VERSION="1.3.0"
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

require_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE
  Create one with: chromeman init"
}

# =============================================================================
# Config parsing — populates WORKSPACES[], URLS[], PROFILES[]
# =============================================================================

load_config() {
    WORKSPACES=()
    URLS=()
    PROFILES=()

    require_config

    local max_n
    max_n=$(grep -oP 'DISPLAY_\K[0-9]+' "$CONFIG_FILE" | sort -n | tail -1)
    [[ -n "$max_n" ]] || die "No DISPLAY_* entries found in $CONFIG_FILE"

    for n in $(seq 1 "$max_n"); do
        local ws url prof
        ws=$(grep   "^DISPLAY_${n}_WORKSPACE=" "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        url=$(grep  "^DISPLAY_${n}_URL="       "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')
        prof=$(grep "^DISPLAY_${n}_PROFILE="   "$CONFIG_FILE" | cut -d= -f2 | tr -d '[:space:]')

        if [[ -n "$ws" && -n "$url" && -n "$prof" ]]; then
            WORKSPACES+=("$ws")
            URLS+=("$url")
            PROFILES+=("$prof")
        fi
    done

    [[ ${#WORKSPACES[@]} -gt 0 ]] || die "No valid display entries found in $CONFIG_FILE"
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
# Launch a single Chrome instance onto a workspace
# =============================================================================

launch_one() {
    local workspace="$1"
    local url="$2"
    local profile_name="$3"
    local prof_dir
    prof_dir=$(profile_dir "$profile_name")
    local ws_index=$(( workspace - 1 ))
    local tag="[Display $workspace]"

    log "$tag Switching to workspace $workspace..."
    wmctrl -s "$ws_index"
    sleep 0.3

    log "$tag Launching → $url"
    google-chrome \
        --new-window \
        --kiosk \
        --start-fullscreen \
        --autoplay-policy=no-user-gesture-required \
        --user-data-dir="$prof_dir" \
        --no-default-browser-check \
        --disable-session-crashed-bubble \
        --disable-infobars \
        "$url" &

    local chrome_pid=$!
    log "$tag Chrome started (PID $chrome_pid)"

    # Wait for window then place it correctly
    for i in $(seq 1 20); do
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
            log "$tag Window $win_id found — moving to workspace $workspace"
            wmctrl -i -r "$win_id" -t "$ws_index"
            wmctrl -s "$ws_index"
            sleep 0.3
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
    load_config

    info "Starting ${#WORKSPACES[@]} display(s)..."
    mkdir -p "$DEFAULT_CONFIG_DIR"

    local count=${#WORKSPACES[@]}
    for (( i=0; i<count; i++ )); do
        # Skip if a specific display was requested and this isn't it
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != $(( i+1 )) && \
              "$TARGET_DISPLAY" != "${WORKSPACES[$i]}" ]]; then
            continue
        fi

        if is_running "${PROFILES[$i]}"; then
            ok "Display ${WORKSPACES[$i]} already running — skipping."
        elif is_paused "${PROFILES[$i]}"; then
            if [[ -n "$TARGET_DISPLAY" ]]; then
                # Explicit single-display start clears the pause lock
                resume_display "${PROFILES[$i]}"
                info "Display ${WORKSPACES[$i]} unpaused."
                local url="${OVERRIDE_URL:-${URLS[$i]}}"
                launch_one "${WORKSPACES[$i]}" "$url" "${PROFILES[$i]}"
                sleep 1
            else
                warn "Display ${WORKSPACES[$i]} is paused — skipping (run: chromeman resume -d ${WORKSPACES[$i]})."
            fi
        else
            local url="${OVERRIDE_URL:-${URLS[$i]}}"
            launch_one "${WORKSPACES[$i]}" "$url" "${PROFILES[$i]}"
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
                >> "$LOG_FILE" 2>&1 &
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

    local count=${#WORKSPACES[@]}
    for (( i=0; i<count; i++ )); do
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != $(( i+1 )) && \
              "$TARGET_DISPLAY" != "${WORKSPACES[$i]}" ]]; then
            continue
        fi

        local prof="${PROFILES[$i]}"
        local ws="${WORKSPACES[$i]}"

        # --no-restart: write a pause lock so the watchdog won't relaunch this display
        if [[ "$NO_RESTART" == "1" ]]; then
            pause_display "$prof"
            info "Display $ws marked as paused (watchdog will not relaunch it)."
        fi

        local pids
        pids=$(get_pids "$prof")

        if [[ -z "$pids" ]]; then
            info "Display $ws not running."
        else
            info "Closing display $ws (PIDs: $pids)..."
            kill $pids 2>/dev/null
        fi
    done

    # Wait then force-kill stragglers
    sleep 3
    for (( i=0; i<count; i++ )); do
        if [[ -n "$TARGET_DISPLAY" && "$TARGET_DISPLAY" != $(( i+1 )) && \
              "$TARGET_DISPLAY" != "${WORKSPACES[$i]}" ]]; then
            continue
        fi
        local remaining
        remaining=$(get_pids "${PROFILES[$i]}")
        if [[ -n "$remaining" ]]; then
            warn "Force-killing display ${WORKSPACES[$i]}..."
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

    local count=${#WORKSPACES[@]}
    for (( i=0; i<count; i++ )); do
        local ws="${WORKSPACES[$i]}"
        local url="${URLS[$i]}"
        local prof="${PROFILES[$i]}"
        local pids
        pids=$(get_pids "$prof")

        if [[ -n "$pids" ]]; then
            printf "  \033[1;32m●\033[0m  Display %-2s  %-40s  PIDs: %s\n" "$ws" "$url" "$pids"
        elif is_paused "$prof"; then
            printf "  \033[1;33m⏸\033[0m  Display %-2s  %-40s  paused\n" "$ws" "$url"
        else
            printf "  \033[1;31m○\033[0m  Display %-2s  %-40s  not running\n" "$ws" "$url"
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
# COMMAND: watch (watchdog loop — called internally, or run directly)
# =============================================================================

cmd_watch() {
    require_wmctrl
    load_config
    mkdir -p "$DEFAULT_CONFIG_DIR"

    log "========================================"
    log "chromeman watchdog started"
    log "Config:   $CONFIG_FILE"
    log "Interval: ${INTERVAL}s"
    log "========================================"

    while true; do
        local count=${#WORKSPACES[@]}
        for (( i=0; i<count; i++ )); do
            local ws="${WORKSPACES[$i]}"
            local url="${URLS[$i]}"
            local prof="${PROFILES[$i]}"

            if is_paused "$prof"; then
                log "[Display $ws] ⏸ Paused — skipping"
            elif is_running "$prof"; then
                log "[Display $ws] ✓ Running"
            else
                log "[Display $ws] ✗ Not running — relaunching → $url"
                launch_one "$ws" "$url" "$prof"
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

    local count=${#WORKSPACES[@]}
    local matched=0
    for (( i=0; i<count; i++ )); do
        if [[ "$TARGET_DISPLAY" != $(( i+1 )) && "$TARGET_DISPLAY" != "${WORKSPACES[$i]}" ]]; then
            continue
        fi
        matched=1
        local prof="${PROFILES[$i]}"
        local ws="${WORKSPACES[$i]}"

        pause_display "$prof"
        info "Display $ws paused — watchdog will no longer relaunch it."

        local pids
        pids=$(get_pids "$prof")
        if [[ -n "$pids" ]]; then
            info "Closing display $ws (PIDs: $pids)..."
            kill $pids 2>/dev/null
            sleep 3
            pids=$(get_pids "$prof")
            [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
        else
            info "Display $ws was not running."
        fi
        ok "Display $ws paused."
    done

    [[ $matched -eq 1 ]] || die "No display matching '$TARGET_DISPLAY' found in config."
}

# =============================================================================
# COMMAND: resume — clear pause lock and relaunch the display
# =============================================================================

cmd_resume() {
    require_wmctrl
    load_config

    [[ -n "$TARGET_DISPLAY" ]] || die "resume requires -d <display>. Example: chromeman resume -d 2"

    local count=${#WORKSPACES[@]}
    local matched=0
    for (( i=0; i<count; i++ )); do
        if [[ "$TARGET_DISPLAY" != $(( i+1 )) && "$TARGET_DISPLAY" != "${WORKSPACES[$i]}" ]]; then
            continue
        fi
        matched=1
        local prof="${PROFILES[$i]}"
        local ws="${WORKSPACES[$i]}"
        local url="${URLS[$i]}"

        if ! is_paused "$prof"; then
            warn "Display $ws is not paused."
        else
            resume_display "$prof"
            ok "Display $ws unpaused."
        fi

        if is_running "$prof"; then
            ok "Display $ws already running."
        else
            local url="${OVERRIDE_URL:-$url}"
            info "Launching display $ws → $url"
            launch_one "$ws" "$url" "$prof"
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
# One block per display. Workspace is 1-indexed (desktop number).

DISPLAY_1_WORKSPACE=1
DISPLAY_1_URL=https://www.example.com
DISPLAY_1_PROFILE=chrome-kiosk-1

DISPLAY_2_WORKSPACE=2
DISPLAY_2_URL=https://www.example2.com
DISPLAY_2_PROFILE=chrome-kiosk-2

DISPLAY_3_WORKSPACE=3
DISPLAY_3_URL=https://www.example3.com
DISPLAY_3_PROFILE=chrome-kiosk-3
EOF
    ok "Config created: $CONFIG_FILE"
    info "Edit it then run: chromeman start"
}

# =============================================================================
# COMMAND: http-server
# Tiny pure-bash HTTP server. Companion hits it to trigger chromeman actions.
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

    command -v nc &>/dev/null || die "netcat (nc) not found. Run: sudo apt install netcat-openbsd"

    echo $$ > "$HTTP_PID_FILE"
    log "[HTTP] chromeman HTTP server listening on port $port"
    log "[HTTP] Endpoints: GET /restart /start /stop /pause /resume /status"
    log "[HTTP] Params:    ?d=<display_number>  &url=<url-encoded-url>"

    trap 'rm -f "$HTTP_PID_FILE"; log "[HTTP] Server stopped."' EXIT INT TERM

    while true; do
        local raw
        raw=$(nc -l -p "$port" -q 1 2>/dev/null)

        # Parse first line: GET /path?query HTTP/1.1
        local first_line method full_path path qs
        first_line=$(echo "$raw" | head -1 | tr -d '\r')
        method=$(echo "$first_line" | awk '{print $1}')
        full_path=$(echo "$first_line" | awk '{print $2}')
        path="${full_path%%\?*}"
        qs=""
        [[ "$full_path" == *"?"* ]] && qs="${full_path#*\?}"

        # Decode query params
        local param_d param_url
        param_d=$(echo "$qs" | grep -oP '(?:^|&)d=\K[^&]+')
        param_url=""
        if echo "$qs" | grep -q 'url='; then
            param_url=$(python3 -c "
import urllib.parse, sys
qs = sys.argv[1]
p = urllib.parse.parse_qs(qs)
print(p.get('url', [''])[0])
" "$qs" 2>/dev/null)
        fi

        local cmd_args="" body="" code="200"

        case "$path" in
            /restart)
                cmd_args="restart"
                [[ -n "$param_d"   ]] && cmd_args+=" -d $param_d"
                [[ -n "$param_url" ]] && cmd_args+=" -u $(printf '%q' "$param_url")"
                body="OK: chromeman $cmd_args"
                ;;
            /start)
                cmd_args="start"
                [[ -n "$param_d"   ]] && cmd_args+=" -d $param_d"
                [[ -n "$param_url" ]] && cmd_args+=" -u $(printf '%q' "$param_url")"
                body="OK: chromeman $cmd_args"
                ;;
            /stop)
                cmd_args="stop"
                [[ -n "$param_d" ]] && cmd_args+=" -d $param_d"
                body="OK: chromeman $cmd_args"
                ;;
            /pause)
                [[ -z "$param_d" ]] && { code="400"; body="ERROR: ?d= required"; } || {
                    cmd_args="pause -d $param_d"
                    body="OK: chromeman $cmd_args"
                }
                ;;
            /resume)
                [[ -z "$param_d" ]] && { code="400"; body="ERROR: ?d= required"; } || {
                    cmd_args="resume -d $param_d"
                    [[ -n "$param_url" ]] && cmd_args+=" -u $(printf '%q' "$param_url")"
                    body="OK: chromeman $cmd_args"
                }
                ;;
            /status)
                load_config 2>/dev/null
                local json='{"displays":['
                local count=${#WORKSPACES[@]}
                for (( i=0; i<count; i++ )); do
                    local state="stopped"
                    is_paused  "${PROFILES[$i]}" && state="paused"
                    is_running "${PROFILES[$i]}" && state="running"
                    [[ $i -gt 0 ]] && json+=","
                    json+="{\"display\":${WORKSPACES[$i]},\"url\":\"${URLS[$i]}\",\"state\":\"$state\"}"
                done
                json+="],"
                watchdog_running && json+='"watchdog":"running"' || json+='"watchdog":"stopped"'
                json+="}"
                body="$json"
                ;;
            /favicon.ico) code="204"; body="" ;;
            *)             code="404"; body="ERROR: unknown endpoint '$path'" ;;
        esac

        # Send HTTP response
        printf "HTTP/1.1 %s OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
            "$code" "${#body}" "$body" | nc -l -p "$port" -q 1 2>/dev/null &

        # Fire the chromeman command asynchronously
        if [[ -n "$cmd_args" && "$code" == "200" ]]; then
            log "[HTTP] $method $full_path → chromeman $cmd_args"
            export DISPLAY="${DISPLAY:-:0}"
            bash -c "$SCRIPT_PATH $cmd_args --config '$CONFIG_FILE'" >> "$LOG_FILE" 2>&1 &
        elif [[ "$code" != "204" ]]; then
            log "[HTTP] $method $full_path → $code $body"
        fi

        wait 2>/dev/null
    done
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
    watch)          cmd_watch ;;
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
