#!/usr/bin/env bash
# Rocky Linux GNOME Desktop Configuration Script (GNOME 49)
# Idempotent: Safe to run multiple times.
#
# Usage:
#   ./setup.sh            Run with normal output
#   DEBUG=1 ./setup.sh    Run with verbose debug tracing
set -euo pipefail

if [[ "${DEBUG:-0}" == "1" ]]; then
    export PS4='+ ${C_DBG:-}[${BASH_SOURCE##*/}:${LINENO}] »${C_RST:-} '
    set -x
fi

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

trap 'rc=$?; if [[ $rc -ne 0 ]]; then error "Failure at line $LINENO (exit=$rc): ${BASH_COMMAND}"; fi' ERR

# ---------------------------------------------------------------------------
# Idempotent helpers
# ---------------------------------------------------------------------------
ensure_gsetting() {
    local schema="$1" key="$2" val="$3"
    local cur
    cur=$(gsettings get "$schema" "$key" 2>/dev/null || echo "__UNSET__")
    if [[ "$cur" != "$val" ]]; then
        gsettings set "$schema" "$key" "$val"
        success "Updated: $schema $key  (was: ${cur:0:60})"
    else
        info "Unchanged: $schema $key"
    fi
}

# For schemas bundled inside a GNOME extension directory
ensure_gsetting_local() {
    local schema_dir="$1" schema="$2" key="$3" val="$4"
    local cur
    cur=$(GSETTINGS_SCHEMA_DIR="$schema_dir" gsettings get "$schema" "$key" 2>/dev/null || echo "__UNSET__")
    if [[ "$cur" != "$val" ]]; then
        GSETTINGS_SCHEMA_DIR="$schema_dir" gsettings set "$schema" "$key" "$val"
        success "Updated: $schema $key  (was: ${cur:0:60})"
    else
        info "Unchanged: $schema $key"
    fi
}

ensure_dconf() {
    local path="$1" val="$2"
    local cur
    cur=$(dconf read "$path" 2>/dev/null || echo "__UNSET__")
    if [[ "$cur" != "$val" ]]; then
        dconf write "$path" "$val"
        success "Updated: $path  (was: ${cur:0:60})"
    else
        info "Unchanged: $path"
    fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ "$EUID" -eq 0 ]] && { error "Do not run as root."; exit 1; }

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    error "No graphical session detected (DISPLAY/WAYLAND_DISPLAY unset)."
    exit 1
fi

if ! cmd_exists gnome-shell; then
    error "gnome-shell not found. This script requires a GNOME session."
    exit 1
fi

GNOME_VER=$(gnome-shell --version 2>/dev/null | grep -oP '\d+' | head -1)
[[ -z "$GNOME_VER" ]] && { error "Could not determine GNOME Shell version."; exit 1; }
info "GNOME Shell version: $GNOME_VER"

# ---------------------------------------------------------------------------
# Step 1: Dependencies
# ---------------------------------------------------------------------------
section "Dependencies"
CORE_PACKAGES=()
for p in nano curl unzip jq python3; do
    cmd_exists "$p" || CORE_PACKAGES+=("$p")
done

if [[ ${#CORE_PACKAGES[@]} -gt 0 ]]; then
    info "Installing: ${CORE_PACKAGES[*]}"
    sudo dnf install -y "${CORE_PACKAGES[@]}"
    success "Core dependencies installed."
else
    success "All core dependencies already present."
fi

# ---------------------------------------------------------------------------
# Step 2: System Performance
# ---------------------------------------------------------------------------
section "System Performance"
PP_SET=false
PP_DBUS="net.hadess.PowerProfiles"
PP_PATH="/net/hadess/PowerProfiles"
PP_PROP=""

if gdbus introspect --system --dest "$PP_DBUS" --object-path "$PP_PATH" &>/dev/null; then
    info "PowerProfiles D-Bus interface found."
    if gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
        --method org.freedesktop.DBus.Properties.Get "$PP_DBUS" Profile &>/dev/null; then
        PP_PROP="Profile"
    elif gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
        --method org.freedesktop.DBus.Properties.Get "$PP_DBUS" ActiveProfile &>/dev/null; then
        PP_PROP="ActiveProfile"
    fi

    if [[ -n "$PP_PROP" ]]; then
        info "Setting $PP_PROP to performance..."
        if sudo gdbus call --system --dest "$PP_DBUS" --object-path "$PP_PATH" \
            --method org.freedesktop.DBus.Properties.Set "$PP_DBUS" "$PP_PROP" \
            "<'performance'>" &>/dev/null; then
            success "Power profile set to performance via D-Bus ($PP_PROP)."
            PP_SET=true
        else
            warning "Failed to set power profile via D-Bus."
        fi
    fi
fi

if [[ "$PP_SET" == false ]] && cmd_exists tuned-adm; then
    info "Falling back to tuned-adm..."
    sudo tuned-adm profile throughput-performance &>/dev/null && PP_SET=true \
        && success "Set to throughput-performance via tuned-adm." \
        || warning "tuned-adm profile switch failed."
fi

if [[ "$PP_SET" == true ]]; then
    SERVICE_FILE="/etc/systemd/system/enforce-performance.service"
    if [[ ! -f "$SERVICE_FILE" ]]; then
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
        systemctl is-enabled enforce-performance.service &>/dev/null \
            && info "Performance enforcement service already exists and is enabled." \
            || { sudo systemctl enable enforce-performance.service >/dev/null
                 success "Performance enforcement service now enabled."; }
    fi
else
    warning "Could not set performance mode. Skipping enforcement service."
fi

# ---------------------------------------------------------------------------
# Step 3: Window buttons & Dark theme
# ---------------------------------------------------------------------------
section "Desktop UI & Behavior"
ensure_gsetting "org.gnome.desktop.wm.preferences" "button-layout" "':minimize,maximize,close'"
ensure_gsetting "org.gnome.desktop.interface"       "color-scheme"  "'prefer-dark'"

# ---------------------------------------------------------------------------
# Step 4: GNOME Extensions — install + enable
# ---------------------------------------------------------------------------
section "GNOME Extensions"
EXTENSIONS_DIR="$HOME/.local/share/gnome-shell/extensions"
mkdir -p "$EXTENSIONS_DIR"

install_extension() {
    local EXT_ID="$1" EXT_UUID="$2" TMP_ZIP DOWNLOAD_URL
    if gnome-extensions info "$EXT_UUID" &>/dev/null; then
        info "$EXT_UUID already installed; skipping download."
        return 0
    fi

    TMP_ZIP="/tmp/${EXT_UUID}.zip"
    info "Fetching: $EXT_UUID (ID: $EXT_ID, GNOME: $GNOME_VER)"
    DOWNLOAD_URL=$(curl -sf --max-time 15 \
        "https://extensions.gnome.org/extension-info/?pk=${EXT_ID}&shell_version=${GNOME_VER}" \
        | jq -r '.download_url // empty' 2>/dev/null || true)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        warning "No compatible build for $EXT_UUID on GNOME $GNOME_VER."
        return 1
    fi

    curl -sL --max-time 60 -o "$TMP_ZIP" "https://extensions.gnome.org${DOWNLOAD_URL}" \
        || { warning "Download failed: $EXT_UUID"; return 1; }

    unzip -t "$TMP_ZIP" &>/dev/null || { warning "Corrupt zip: $EXT_UUID"; rm -f "$TMP_ZIP"; return 1; }

    if gnome-extensions install --force "$TMP_ZIP" 2>/dev/null; then
        success "$EXT_UUID installed via gnome-extensions."
    else
        mkdir -p "$EXTENSIONS_DIR/$EXT_UUID"
        unzip -oq "$TMP_ZIP" -d "$EXTENSIONS_DIR/$EXT_UUID/"
        success "$EXT_UUID installed via unzip fallback."
    fi
    rm -f "$TMP_ZIP"
}

enable_extension() {
    local UUID="$1"
    local current
    current=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")

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
        gsettings set org.gnome.shell enabled-extensions "$new_list"
        success "Added $UUID to enabled-extensions."
    fi

    gnome-extensions enable "$UUID" 2>/dev/null \
        || warning "gnome-extensions enable returned non-zero for $UUID (may need re-login)."
}

EXTS=(
    "1160:dash-to-panel@jderose9.github.com"
    "3628:arcmenu@arcmenu.com"
    "4099:no-overview@fthx"
)
for e in "${EXTS[@]}"; do
    IFS=':' read -r id uuid <<< "$e"
    install_extension "$id" "$uuid" || warning "$uuid skipped."
done

section "Enabling Extensions"
enable_extension "dash-to-panel@jderose9.github.com"
enable_extension "arcmenu@arcmenu.com"
enable_extension "no-overview@fthx"

# ---------------------------------------------------------------------------
# Step 5: Dash to Panel configuration
# ---------------------------------------------------------------------------
section "Dash to Panel Configuration"
DTP_CONFIGURED=false
DTP_PATH="/org/gnome/shell/extensions/dash-to-panel/"

PANEL_ELEMENTS='{"unknown-unknown":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},{"element":"desktopButton","visible":true,"position":"stackedBR"}]}'

ensure_dconf "${DTP_PATH}animate-appicon-hover-animation-extent" \
    "{'RIPPLE': 4, 'PLANK': 4, 'SIMPLE': 1}"
ensure_dconf "${DTP_PATH}dot-position"                  "'BOTTOM'"
ensure_dconf "${DTP_PATH}hotkeys-overlay-combo"         "'TEMPORARILY'"
ensure_dconf "${DTP_PATH}panel-anchors"                 "'{\"unknown-unknown\":\"MIDDLE\"}'"
ensure_dconf "${DTP_PATH}panel-element-positions"       "'${PANEL_ELEMENTS}'"
ensure_dconf "${DTP_PATH}panel-lengths"                 "'{}'"
ensure_dconf "${DTP_PATH}panel-positions"               "'{}'"
ensure_dconf "${DTP_PATH}panel-sizes"                   "'{}'"
ensure_dconf "${DTP_PATH}window-preview-title-position" "'TOP'"
DTP_CONFIGURED=true

# ---------------------------------------------------------------------------
# Step 6: Arc Menu configuration
# ---------------------------------------------------------------------------
section "Arc Menu Configuration"
ARC_EXT_DIR="$HOME/.local/share/gnome-shell/extensions/arcmenu@arcmenu.com"
ARC_SCHEMA_DIR="$ARC_EXT_DIR/schemas"
ARC_DCONF_PATH="/org/gnome/shell/extensions/arcmenu/"
ARC_CONFIGURED=false

# GNOME Shell extensions keep their schemas locally. We point gsettings to
# the extension's schema directory so it applies live without needing a
# system-wide schema installation.
if [[ -f "$ARC_SCHEMA_DIR/gschemas.compiled" ]]; then
    info "Arc Menu local schema found — applying via GSettings (live update)."
    ensure_gsetting_local "$ARC_SCHEMA_DIR" "org.gnome.shell.extensions.arcmenu" \
        "menu-layout" "'windows'"
    ensure_gsetting_local "$ARC_SCHEMA_DIR" "org.gnome.shell.extensions.arcmenu" \
        "prefs-visible-page" "0"
    ensure_gsetting_local "$ARC_SCHEMA_DIR" "org.gnome.shell.extensions.arcmenu" \
        "search-entry-border-radius" "(true, uint32 25)"
    ensure_gsetting_local "$ARC_SCHEMA_DIR" "org.gnome.shell.extensions.arcmenu" \
        "update-notifier-project-version" "uint32 73"
    ARC_CONFIGURED=true
    success "Arc Menu settings applied."
else
    warning "Arc Menu schema not compiled locally; falling back to dconf."
    ensure_dconf "${ARC_DCONF_PATH}menu-layout"                     "'windows'"
    ensure_dconf "${ARC_DCONF_PATH}prefs-visible-page"              "0"
    ensure_dconf "${ARC_DCONF_PATH}search-entry-border-radius"      "(true, uint32 25)"
    ensure_dconf "${ARC_DCONF_PATH}update-notifier-project-version" "uint32 73"
    ARC_CONFIGURED=true
    success "Arc Menu settings written to dconf (will apply after re-login)."
fi

# ---------------------------------------------------------------------------
# Step 7: Firefox — uBlock Origin system-wide install
# ---------------------------------------------------------------------------
section "Firefox — uBlock Origin (system-wide)"
UBLOCK_UUID="uBlock0@raymondhill.net"
UBLOCK_TARGET="/usr/lib64/firefox/browser/extensions"
UBLOCK_DEST="${UBLOCK_TARGET}/${UBLOCK_UUID}.xpi"
UBLOCK_URL_AMO="https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
UBLOCK_INSTALLED=false

# Validate existing install. If it's a valid zip, we skip downloading.
if [[ -f "$UBLOCK_DEST" ]] && unzip -t "$UBLOCK_DEST" &>/dev/null; then
    UBLOCK_INSTALLED=true
    info "uBlock Origin already installed and valid; skipping download."
else
    info "Downloading uBlock Origin..."
    TMP_XPI=$(mktemp /tmp/ublock-XXXXXX.xpi)
    DOWNLOAD_OK=false

    # Method 1: AMO direct link. 
    # -4 forces IPv4 (bypasses IPv6 routing bugs in VMs)
    # -f fails fast on HTTP errors (prevents saving HTML error pages as XPI)
    if curl -4 -fL --max-time 120 \
            -A "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0" \
            --retry 3 --retry-delay 2 \
            "$UBLOCK_URL_AMO" -o "$TMP_XPI" \
        && [[ -s "$TMP_XPI" ]] \
        && unzip -t "$TMP_XPI" &>/dev/null; then
        DOWNLOAD_OK=true
    else
        warning "AMO download failed (curl exit: $?), trying GitHub API..."
        # Method 2: GitHub Releases API
        GH_URL=$(curl -4 -fsL "https://api.github.com/repos/gorhill/uBlock/releases/latest" \
            | jq -r '.assets[] | select(.name | contains("firefox.signed")) | .browser_download_url' 2>/dev/null)
        if [[ -n "$GH_URL" ]] && \
           curl -4 -fL --max-time 120 "$GH_URL" -o "$TMP_XPI" && \
           unzip -t "$TMP_XPI" &>/dev/null; then
            DOWNLOAD_OK=true
        fi
    fi

    if [[ "$DOWNLOAD_OK" == true ]]; then
        sudo mkdir -p "$UBLOCK_TARGET"
        sudo cp -f "$TMP_XPI" "$UBLOCK_DEST"
        sudo chmod 644 "$UBLOCK_DEST"
        UBLOCK_INSTALLED=true
        success "uBlock Origin installed → $UBLOCK_DEST"
    else
        warning "All uBlock Origin download methods failed."
    fi
    rm -f "$TMP_XPI"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${C_OK}============================================================${C_RST}"
echo -e "${C_OK}  Configuration Complete!${C_RST}"
echo -e "${C_OK}============================================================${C_RST}"
echo ""
printf "  %-30s %s\n" "GNOME version:" "$GNOME_VER"
echo ""
echo "  Changes applied:"
echo "    ✔  Dependencies checked"
[[ "$PP_SET"           == true ]] \
    && echo "    ✔  System performance mode enabled (persisted via systemd)" \
    || echo "    ✘  Performance mode failed"
echo "    ✔  Window buttons: minimize / maximize / close"
echo "    ✔  System dark theme"
echo "    ✔  Login overview disabled (via no-overview extension)"
echo "    ✔  Dash to Panel installed + enabled"
[[ "$DTP_CONFIGURED"   == true ]] \
    && echo "    ✔  Dash to Panel configured (Windows-style taskbar)" \
    || echo "    ✘  Dash to Panel config skipped"
echo "    ✔  Arc Menu installed + enabled"
[[ "$ARC_CONFIGURED"   == true ]] \
    && echo "    ✔  Arc Menu configured (layout=windows, search-radius=25)" \
    || echo "    ✘  Arc Menu config skipped"
[[ "$UBLOCK_INSTALLED" == true ]] \
    && echo "    ✔  uBlock Origin installed system-wide for Firefox" \
    || echo "    ✘  uBlock Origin install failed"
echo ""
echo "  Layout: ShowApps/Activities hidden | Taskbar left | Clock+System right | Desktop far right | Dots bottom"
echo ""
echo -e "${C_WARN}  ➜  Log out and back in for GNOME Shell changes to fully take effect.${C_RST}"
echo ""
exit 0
