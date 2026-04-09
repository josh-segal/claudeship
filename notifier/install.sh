#!/bin/bash
#
# install.sh — Install claudeship-notifier daemon + bar adapters on Linux
#
# Symlinks scripts to ~/.local/bin and optionally creates a systemd user service.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"

echo "claudeship-notifier installer"
echo "=============================="
echo

# ── Symlink daemon + adapters to ~/.local/bin ────────────────────────────────

mkdir -p "$BIN_DIR"

symlink_script() {
    local src="$1" name="$2"
    chmod +x "$src"
    if [ -L "${BIN_DIR}/${name}" ]; then
        rm "${BIN_DIR}/${name}"
    fi
    ln -sf "$src" "${BIN_DIR}/${name}"
    echo "  ✓ ${name} → ${src}"
}

echo "Installing scripts to ${BIN_DIR}:"
symlink_script "${SCRIPT_DIR}/daemon/claudeship-notifier.py" "claudeship-notifier"
symlink_script "${SCRIPT_DIR}/adapters/waybar/claudeship-waybar-adapter.py" "claudeship-waybar-adapter"
echo

# ── Ensure ~/.local/bin is in PATH ──────────────────────────────────────────

if ! echo "$PATH" | tr ':' '\n' | grep -qx "${BIN_DIR}"; then
    echo "⚠ ${BIN_DIR} is not in your PATH."
    echo "  Add this to your ~/.zshrc or ~/.bashrc:"
    echo "    export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    echo
fi

# ── systemd user service (optional) ─────────────────────────────────────────

SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/claudeship-notifier.service"

install_service() {
    mkdir -p "$SERVICE_DIR"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Claudeship notification daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/claudeship-notifier
Restart=on-failure
RestartSec=3
Environment=DISPLAY=%I
Environment=WAYLAND_DISPLAY=wayland-1

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now claudeship-notifier.service
    echo "  ✓ systemd service enabled and started"
}

echo "Install systemd user service?"
echo "  This runs the daemon automatically on login."
echo "  (You can also run it manually or let Waybar manage it.)"
read -rp "  Install service? [Y/n] " answer
case "${answer:-y}" in
    [Yy]*|"")
        install_service
        ;;
    *)
        echo "  Skipped. Run manually: claudeship-notifier"
        ;;
esac
echo

# ── Print Waybar config snippets ────────────────────────────────────────────

echo "=============================="
echo "Waybar Setup"
echo "=============================="
echo
echo "1. Add \"custom/claudeship\" to your modules array in ~/.config/waybar/config.jsonc"
echo
echo "2. Add this module config:"
echo
cat "${SCRIPT_DIR}/adapters/waybar/waybar-module.jsonc" | grep -v '^//'
echo
echo "3. Add styles from: ${SCRIPT_DIR}/adapters/waybar/waybar-style.css"
echo "   to your ~/.config/waybar/style.css"
echo
echo "4. Reload Waybar: killall -SIGUSR2 waybar"
echo
echo "Done! The daemon will start receiving notifications from Claude Code hooks."
