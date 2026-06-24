#!/bin/bash
set -e

REPO_DIR=$(pwd)
if [ ! -f "$REPO_DIR/bin/procmon-collect" ]; then
    echo "Please run this script from the repository directory."
    exit 1
fi

BIN_DIR="$HOME/.local/bin"
PLASMOID_SRC="$REPO_DIR/plasmoids"
CFG_DIR="$HOME/.config/Linux-Process-Mon"

for bin in python3 kpackagetool6; do
    command -v "$bin" >/dev/null 2>&1 || echo "Warning: '$bin' is not installed or not in PATH."
done
python3 -c "import pynvml" >/dev/null 2>&1 || echo "Note: install python-nvidia-ml-py for GPU stats:  sudo pacman -S python-nvidia-ml-py"

# --- 1. collector onto PATH (symlinked back to the repo) ---
mkdir -p "$BIN_DIR"
chmod +x "$REPO_DIR/bin/procmon-collect" "$REPO_DIR/bin/procmon-ecores"
ln -sf "$REPO_DIR/bin/procmon-collect" "$BIN_DIR/procmon-collect"
echo "Linked procmon-collect into $BIN_DIR"

# --- 2. config (gitignored; holds the sampling interval) ---
mkdir -p "$CFG_DIR"
[ -f "$CFG_DIR/config.json" ] || cp "$REPO_DIR/config.example.json" "$CFG_DIR/config.json"

# --- 3. let the widget read the tmpfs snapshot in-process via QML XHR ---
# (Qt blocks file:// XHR unless this is set.) environment.d is applied by the
# systemd user manager, so it survives mid-session plasma restarts too.
mkdir -p ~/.config/environment.d
echo 'QML_XHR_ALLOW_FILE_READ=1' > ~/.config/environment.d/linux-process-mon.conf
systemctl --user set-environment QML_XHR_ALLOW_FILE_READ=1 2>/dev/null || true
echo "Set QML_XHR_ALLOW_FILE_READ=1 (environment.d; survives plasma restarts)"

# --- 4. resident collector service, pinned to the E-cores ---
mkdir -p "$HOME/.config/systemd/user"
AFFINITY=""
ECORES=$(python3 -S "$REPO_DIR/bin/procmon-ecores" 2>/dev/null)
[ -n "$ECORES" ] && AFFINITY="CPUAffinity=$ECORES" && echo "Pinning collector to efficiency cores: $ECORES"
cat > "$HOME/.config/systemd/user/linux-process-mon.service" <<EOF
[Unit]
Description=Linux-Process-Mon resident collector
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $REPO_DIR/bin/procmon-collect --serve
Restart=always
RestartSec=5
Nice=19
$AFFINITY

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now linux-process-mon.service >/dev/null 2>&1 \
    && echo "Enabled resident collector (linux-process-mon.service)" \
    || echo "  (could not enable linux-process-mon.service -- enable it manually)"

# --- 5. install the widget ---
if [ ! -e "$REPO_DIR/shared/common/FileWatcher.qml" ]; then
    echo "  ! shared/common (Linux-Plasma-Shared submodule) is empty." >&2
    echo "    Run: git submodule update --init --recursive" >&2
    exit 1
fi
echo "Installing widget..."
for d in "$PLASMOID_SRC"/org.devl0rd.procmon*; do
    cp "$REPO_DIR/shared/common/FileWatcher.qml" "$REPO_DIR/shared/common/Sparkline.qml" "$d/contents/ui/"  # shared (submodule) components
    if kpackagetool6 -t Plasma/Applet -u "$d" >/dev/null 2>&1; then
        echo "  upgraded $(basename "$d")"
    else
        kpackagetool6 -t Plasma/Applet -i "$d" >/dev/null 2>&1 && echo "  installed $(basename "$d")"
    fi
done

echo ""
echo "Done! Add it via right-click panel/desktop -> Add Widgets -> search \"Process Monitor\"."
echo "If it doesn't appear yet, run:  systemctl --user restart plasma-plasmashell.service"

# reload Plasma at the end -- unless --no-reload (so bulk installs can reload once)
if ! printf '%s\n' "$@" | grep -qx -- --no-reload; then
    echo "Reloading Plasma…"
    # plasmashell may be run by plasma-plasmashell.service OR as an app-plasmashell@<hash>
    # scope (then plasma-plasmashell.service is inactive and "restarting" it just spawns a
    # doomed duplicate). Restart the unit only when it actually runs the shell; otherwise
    # quit + relaunch the running instance directly.
    if systemctl --user --quiet is-active plasma-plasmashell.service; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null; (kstart plasmashell >/dev/null 2>&1 &)
    fi
fi
