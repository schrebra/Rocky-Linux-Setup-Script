#!/usr/bin/env bash
# Rocky Linux GNOME Desktop Configuration Script (GNOME 49)
# Idempotent: Safe to run multiple times.
#
# Usage:
#   ./setup.sh            Run with normal output
#   DEBUG=1 ./setup.sh    Run with verbose debug tracing
set -euo pipefail

# Debug support: set DEBUG=1 for command tracing with source/line info
if [[ "${DEBUG:-0}" == "1" ]]; then
    export PS4='+ ${C_DBG:-}[${BASH_SOURCE##*/}:${LINENO}] »${C_RST:-} '
    set -x
fi

# Colors (auto-disabled when output is not a TTY)
if [[ -t 1 ]]; then
    C_INFO='\e[34m'; C_OK='\e[32m'; C_WARN='\e[33m'; C_ERR='\e[31m'
    C_SEC='\e[35m';  C_DBG='\e[90m'; C_RST='\e[0m'
else
    C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_SEC=''; C_DBG=''; C_RST=''
fi

info()    { echo -e "${C_INFO}[INFO]${C_RST}  $*"; }
success() { echo -e "${C_OK}[OK]${C_RST}    $*"; }
warning() { echo -e "${C_WARN}[WARN]${C_RST}  $*"; }
error()   { echo -e "${C_ERR}[ERROR]${C_RST} $*" >&2; }
section() { echo -e "\n${C_SEC}=== $* ===${C_RST}"; }
debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${C_DBG}[DBG]${C_RST}   $*" >&2 || true; }

# Trap errors with context
trap 'rc=$?; if [[ $rc -ne 0 ]]; then error "Failure at line $LINENO (exit=$rc): ${BASH_COMMAND}"; fi' ERR

# Idempotent helpers: only write if the value differs
ensure_gsetting() {
    local schema="$1" key="$2" val="$3"
    local cur
    debug "gsettings get $schema $key"
    cur=$(gsettings get "$schema" "$key" 2>/dev/null || echo "__UNSET__")
    debug "current='$cur' desired='$val'"
    if [[ "$cur" != "$val" ]]; then
        gsettings set "$schema" "$key" "$val"
        success "Updated: $schema $key  (was: ${cur:0:60})"
    else
        info "Unchanged: $schema $key"
    fi
}

ensure_dconf() {
    local path="$1" val="$2"
    local cur
    debug "dconf read $path"
    cur=$(dconf read "$path" 2>/dev/null || echo "__UNSET__")
    debug "current='$cur' desired='$val'"
    if [[ "$cur" != "$val" ]]; then
        dconf write "$path" "$val"
        success "Updated: $path  (was: ${cur:0:60})"
    else
        info "Unchanged: $path"
    fi
}

have_schema() {
    debug "checking schema: $1"
    gsettings list-schemas 2>/dev/null | grep -Fxq "$1" \
        || gsettings list-relocatable-schemas 2>/dev/null | grep -Fxq "$1"
}

cmd_exists() { command -v "$1" &>/dev/null; }

# Pre-flight
[[ "$EUID" -eq 0 ]] && { error "Do not run as root."; exit 1; }
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    error "No graphical session detected (DISPLAY/WAYLAND_DISPLAY unset)."
    exit 1
fi
debug "DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
debug "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}"
debug "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}"

if ! cmd_exists gnome-shell; then
    error "gnome-shell not found. This script requires a GNOME session."
    exit 1
fi

GNOME_VER=$(gnome-shell --version 2>/dev/null | grep -oP '\d+' | head -1)
if [[ -z "$GNOME_VER" ]]; then
    error "Could not determine GNOME Shell version."
    exit 1
fi
info "GNOME Shell version: $GNOME_VER"
debug "gnome-shell path: $(command -v gnome-shell)"

# Step 1: Dependencies
section "Dependencies"
CORE_PACKAGES=()
for p in nano curl unzip jq python3; do
    if cmd_exists "$p"; then
        debug "found: $p -> $(command -v "$p")"
    else
        CORE_PACKAGES+=("$p")
        info "Missing dependency: $p"
    fi
done

if [[ ${#CORE_PACKAGES[@]} -gt 0 ]]; then
    info "Installing missing core packages: ${CORE_PACKAGES[*]}"
    debug "sudo dnf install -y ${CORE_PACKAGES[*]}"
    sudo dnf install -y "${CORE_PACKAGES[@]}"
    success "Core dependencies installed."
else
    success "All core dependencies already present."
fi

# Step 2: System Performance
section "System Performance"
PP_SET=false
PP_DBUS="net.hadess.PowerProfiles"
PP_PATH="/net/hadess/PowerProfiles"
PP_PROP=""

debug "Checking PowerProfiles D-Bus interface: $PP_DBUS"
if gdbus introspect --system --dest "$PP_DBUS" --object-path "$PP_PATH" &>/dev/null; then
    info "PowerProfiles D-Bus interface found."
    debug "Probing property names (Profile / ActiveProfile)..."
    if gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
        --method org.freedesktop.DBus.Properties.Get "$PP_DBUS" Profile &>/dev/null; then
        PP_PROP="Profile"
        debug "Property name resolved: Profile"
    elif gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
        --method org.freedesktop.DBus.Properties.Get "$PP_DBUS" ActiveProfile &>/dev/null; then
        PP_PROP="ActiveProfile"
        debug "Property name resolved: ActiveProfile"
    fi

    if [[ -n "$PP_PROP" ]]; then
        info "Setting $PP_PROP to performance..."
        debug "sudo gdbus call --system --dest $PP_DBUS --object-path $PP_PATH Set $PP_DBUS $PP_PROP <'performance'>"
        if sudo gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
            --method org.freedesktop.DBus.Properties.Set "$PP_DBUS" "$PP_PROP" "<'performance'>" &>/dev/null; then
            success "Power profile set to performance via D-Bus ($PP_PROP)."
            PP_SET=true
        else
            warning "Failed to set power profile via D-Bus."
        fi
    else
        warning "Could not determine valid power profile property name."
    fi
else
    debug "PowerProfiles D-Bus interface not available."
fi

# Fallback to tuned-adm if D-Bus failed (Rocky Linux native)
if [[ "$PP_SET" == false ]] && cmd_exists tuned-adm; then
    info "Falling back to tuned-adm (throughput-performance)..."
    debug "sudo tuned-adm profile throughput-performance"
    if sudo tuned-adm profile throughput-performance &>/dev/null; then
        success "System set to throughput-performance via tuned-adm."
        PP_SET=true
    else
        warning "tuned-adm profile switch failed."
    fi
fi

# Create a robust systemd service to enforce on boot using whatever method worked
if [[ "$PP_SET" == true ]]; then
    SERVICE_FILE="/etc/systemd/system/enforce-performance.service"
    if [[ ! -f "$SERVICE_FILE" ]]; then
        info "Creating robust systemd enforcement service..."
        debug "writing $SERVICE_FILE"
        sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Enforce Performance Power Profile
After=power-profiles-daemon.service tuned.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "gdbus call --system --dest $PP_DBUS --object-path $PP_PATH --method org.freedesktop.DBus.Properties.Set $PP_DBUS Profile \\"<'performance'>\\" 2>/dev/null || gdbus call --system --dest $PP_DBUS --object-path $PP_PATH --method org.freedesktop.DBus.Properties.Set $PP_DBUS ActiveProfile \\"<'performance'>\\" 2>/dev/null || tuned-adm profile throughput-performance 2>/dev/null"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable enforce-performance.service >/dev/null
        success "Performance enforcement service created and enabled."
    else
        debug "Service file already exists; checking enabled state..."
        if systemctl is-enabled enforce-performance.service &>/dev/null; then
            info "Performance enforcement service already exists and is enabled."
        else
            sudo systemctl enable enforce-performance.service >/dev/null
            success "Performance enforcement service already exists; now enabled."
        fi
    fi
else
    warning "Could not set performance mode. Skipping enforcement service."
fi

# Step 3: Window buttons & Dark theme
section "Desktop UI & Behavior"
ensure_gsetting "org.gnome.desktop.wm.preferences" "button-layout" "':minimize,maximize,close'"
ensure_gsetting "org.gnome.desktop.interface" "color-scheme" "prefer-dark"

# Step 4: GNOME Extensions install + enable
section "GNOME Extensions"
EXTENSIONS_DIR="$HOME/.local/share/gnome-shell/extensions"
mkdir -p "$EXTENSIONS_DIR"
debug "Extensions dir: $EXTENSIONS_DIR"

install_extension() {
    local EXT_ID EXT_UUID TMP_ZIP
    EXT_ID="$1"
    EXT_UUID="$2"

    debug "Checking if $EXT_UUID is already installed..."
    if gnome-extensions info "$EXT_UUID" &>/dev/null; then
        info "$EXT_UUID already installed; skipping download."
        return 0
    fi

    TMP_ZIP="/tmp/${EXT_UUID}.zip"
    info "Fetching: $EXT_UUID (ID: $EXT_ID, GNOME: $GNOME_VER)"
    debug "GET https://extensions.gnome.org/extension-info/?pk=${EXT_ID}&shell_version=${GNOME_VER}"
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -sf --max-time 15 \
        "https://extensions.gnome.org/extension-info/?pk=${EXT_ID}&shell_version=${GNOME_VER}" \
        | jq -r '.download_url // empty' 2>/dev/null || true)
    if [[ -z "$DOWNLOAD_URL" ]]; then
        warning "No compatible build for $EXT_UUID on GNOME $GNOME_VER."
        return 1
    fi
    debug "download_url=$DOWNLOAD_URL"

    info "Downloading: https://extensions.gnome.org${DOWNLOAD_URL}"
    debug "curl -sL --max-time 60 -o $TMP_ZIP ..."
    if ! curl -sL --max-time 60 -o "$TMP_ZIP" "https://extensions.gnome.org${DOWNLOAD_URL}"; then
        warning "Download failed: $EXT_UUID"
        return 1
    fi
    debug "Downloaded bytes: $(stat -c %s "$TMP_ZIP" 2>/dev/null || echo '?')"

    debug "Validating zip integrity: $TMP_ZIP"
    if ! unzip -t "$TMP_ZIP" &>/dev/null; then
        warning "Invalid or corrupt zip: $EXT_UUID"
        rm -f "$TMP_ZIP"
        return 1
    fi

    debug "Installing via gnome-extensions install --force"
    if gnome-extensions install --force "$TMP_ZIP" 2>/dev/null; then
        success "$EXT_UUID installed via gnome-extensions."
    else
        debug "gnome-extensions install failed; falling back to unzip"
        mkdir -p "$EXTENSIONS_DIR/$EXT_UUID"
        unzip -oq "$TMP_ZIP" -d "$EXTENSIONS_DIR/$EXT_UUID/"
        success "$EXT_UUID installed via unzip fallback."
    fi
    rm -f "$TMP_ZIP"
}

enable_extension() {
    local UUID="$1"
    local current
    debug "Reading enabled-extensions list"
    current=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")
    debug "current enabled-extensions: $current"

    if echo "$current" | grep -qF "$UUID"; then
        info "$UUID already in enabled-extensions list."
    else
        local new_list
        new_list=$(python3 -c '
import ast, sys
raw, uuid = sys.argv[1], sys.argv[2]
try:
    lst = ast.literal_eval(raw)
    if not isinstance(lst, list): raise ValueError
except Exception:
    lst = []
if uuid not in lst:
    lst.append(uuid)
print(str(lst).replace("\"", "'\''"))
' "$current" "$UUID")
        debug "new enabled-extensions: $new_list"
        gsettings set org.gnome.shell enabled-extensions "$new_list"
        success "Added $UUID to enabled-extensions."
    fi

    debug "gnome-extensions enable $UUID"
    gnome-extensions enable "$UUID" 2>/dev/null || warning "gnome-extensions enable returned non-zero for $UUID (may need re-login)."
}

EXTS=(
    "1160:dash-to-panel@jderose9.github.com"
    "3628:arcmenu@arcmenu.com"
    "4099:no-overview@fthx"
)
for e in "${EXTS[@]}"; do
    IFS=':' read -r id uuid <<< "$e"
    debug "Processing extension entry: id=$id uuid=$uuid"
    install_extension "$id" "$uuid" || warning "$uuid skipped."
done

section "Enabling Extensions"
enable_extension "dash-to-panel@jderose9.github.com"
enable_extension "arcmenu@arcmenu.com"
enable_extension "no-overview@fthx"

# Step 5: Dash to Panel config
section "Dash to Panel Configuration"
DTP_CONFIGURED=false
DTP_PATH="/org/gnome/shell/extensions/dash-to-panel/"
debug "DTP dconf path: $DTP_PATH"

PANEL_ELEMENTS='{"unknown-unknown":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},{"element":"desktopButton","visible":true,"position":"stackedBR"}]}'

ensure_dconf "${DTP_PATH}animate-appicon-hover-animation-extent" "{'RIPPLE': 4, 'PLANK': 4, 'SIMPLE': 1}"
ensure_dconf "${DTP_PATH}dot-position" "'BOTTOM'"
ensure_dconf "${DTP_PATH}hotkeys-overlay-combo" "'TEMPORARILY'"
ensure_dconf "${DTP_PATH}panel-anchors" "'{\"unknown-unknown\":\"MIDDLE\"}'"
ensure_dconf "${DTP_PATH}panel-element-positions" "'${PANEL_ELEMENTS}'"
ensure_dconf "${DTP_PATH}panel-lengths" "'{}'"
ensure_dconf "${DTP_PATH}panel-positions" "'{}'"
ensure_dconf "${DTP_PATH}panel-sizes" "'{}'"
ensure_dconf "${DTP_PATH}window-preview-title-position" "'TOP'"

DTP_CONFIGURED=true

# Summary
echo ""
echo -e "${C_OK}============================================================${C_RST}"
echo -e "${C_OK}  Configuration Complete!${C_RST}"
echo -e "${C_OK}============================================================${C_RST}"
echo ""
printf "  %-30s %s\n" "GNOME version:" "$GNOME_VER"
echo ""
echo "  Changes applied:"
echo "    ✔  Dependencies checked"
if [[ "$PP_SET" == true ]]; then
    echo "    ✔  System performance mode enabled (persisted via systemd)"
else
    echo "    ✘  Performance mode failed"
fi
echo "    ✔  Window buttons: minimize / maximize / close"
echo "    ✔  System dark theme"
echo "    ✔  Login overview disabled (via extension)"
echo "    ✔  Dash to Panel installed + enabled"
[[ "$DTP_CONFIGURED" == true ]] && echo "    ✔  Dash to Panel configured (Windows-style taskbar)" || echo "    ✘  Dash to Panel config skipped"
echo "    ✔  Arc Menu installed + enabled"
echo ""
echo "  Layout: ShowApps/Activities hidden | Taskbar left | Clock+System right | Desktop far right | Dots bottom"
echo ""
echo -e "${C_WARN}  ➜  Log out and back in for GNOME Shell changes (extensions/overview) to fully take effect.${C_RST}"
echo ""
exit 0
