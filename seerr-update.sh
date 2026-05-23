#!/bin/bash
# Update an existing seerr install to a custom fork, preserving data + config.
# Companion to seerr.sh — same environment assumptions (nvm/pnpm, systemd --user).
#
# What it does:
#   1. stops the seerr service
#   2. builds your fork in a fresh directory (~/seerr-new)
#   3. carries over your existing config/ (DB, settings) and env.conf (port)
#   4. swaps the new build into place (old kept as ~/seerr.old)
#   5. restarts the service and verifies it came up
#
# It does NOT touch your database, settings, port, nginx, or the swizzin panel.
# If the build fails, your old install is left untouched and restarted.

set -euo pipefail

# --- Help --------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage:
  ./seerr-update.sh [OPTIONS]
  sudo ./seerr-update.sh [OPTIONS]

Update an existing seerr install to a custom fork, preserving all data and
config. Stops the service, builds the fork in a fresh directory, carries over
config/db/env.conf, swaps the new build into place, and restarts.

Options:
  -u, --url <url>     Git URL of the fork to build
                      (default: https://github.com/Flawkee/seerr.git)
  -r, --ref <ref>     Branch, tag, or commit to checkout after cloning
                      (default: the remote's default branch)
  -h, --help          Show this help message and exit

Environment variables (alternative to flags):
  FORK_URL            Same as --url
  FORK_REF            Same as --ref

Examples:
  # Update from your fork's default branch
  sudo ./seerr-update.sh

  # Update from a specific branch
  sudo ./seerr-update.sh --ref my-feature-branch

  # Update from a different fork entirely
  sudo ./seerr-update.sh --url https://github.com/someone/seerr.git --ref v1.2.3

  # Using environment variables
  FORK_REF=main sudo ./seerr-update.sh

Safety:
  - The previous build is kept at ~/seerr.old until you delete it manually.
  - If the build fails, your old install is left untouched and restarted.
  - The script refuses to run if ~/seerr-new or ~/seerr.old already exist.

Rollback (if something goes wrong after the swap):
  systemctl --user stop seerr
  rm -rf ~/seerr && mv ~/seerr.old ~/seerr
  systemctl --user start seerr
EOF
}

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)  FORK_URL="$2"; shift 2 ;;
        -r|--ref)  FORK_REF="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    esac
done

# --- Config ------------------------------------------------------------------
FORK_URL="${FORK_URL:-https://github.com/Flawkee/seerr.git}"
FORK_REF="${FORK_REF:-}"

# --- Privilege detection (mirrors seerr.sh) ----------------------------------
if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" ]] || [[ "$SUDO_USER" == "root" ]]; then
        echo "Run this script with sudo from your normal user account (not directly as root)."
        exit 1
    fi
    SUDO_MODE=true
    target_user="$SUDO_USER"
else
    SUDO_MODE=false
    target_user="$(whoami)"
fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"

log="$target_home/.logs/seerr.log"
mkdir -p "$target_home/.logs/"
touch "$log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi

run_as_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" -H bash -lc "$1"
    else
        bash -lc "$1"
    fi
}

systemctl_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" \
            XDG_RUNTIME_DIR="/run/user/$target_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
            systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

APP="$target_home/seerr"
NEW="$target_home/seerr-new"
OLD="$target_home/seerr.old"

# --- Pre-flight checks -------------------------------------------------------
if [[ ! -d "$APP" ]]; then
    echo "No existing install found at $APP. Use seerr.sh to install first."
    exit 1
fi
if [[ ! -d "$APP/config" ]]; then
    echo "WARNING: $APP/config not found — there may be no data to preserve."
    read -r -p "Continue anyway? [yes/no]: " ans
    [[ "$ans" == "yes" ]] || { echo "Aborting."; exit 1; }
fi
if [[ -e "$NEW" ]]; then
    echo "$NEW already exists. Remove it first: rm -rf '$NEW'"
    exit 1
fi
if [[ -e "$OLD" ]]; then
    echo "$OLD already exists (from a previous update). Remove it first: rm -rf '$OLD'"
    exit 1
fi

echo "Updating seerr for user '$target_user' from $FORK_URL${FORK_REF:+ (ref: $FORK_REF)}"
echo ""

# --- 1. Stop the service -----------------------------------------------------
echo "Stopping seerr service..."
systemctl_user stop seerr 2>/dev/null || true

# --- 2. Build the fork in a fresh directory ----------------------------------
echo "Cloning fork into $NEW"
run_as_user "git clone '$FORK_URL' '$NEW'" >> "$log" 2>&1 || {
    echo "Clone failed. See $log"
    systemctl_user start seerr 2>/dev/null || true
    exit 1
}

if [[ -n "$FORK_REF" ]]; then
    run_as_user "git -C '$NEW' checkout '$FORK_REF'" >> "$log" 2>&1 || {
        echo "Could not checkout ref '$FORK_REF'. See $log"
        run_as_user "rm -rf '$NEW'"
        systemctl_user start seerr 2>/dev/null || true
        exit 1
    }
fi

# Same tweaks the installer applies: bypass Node engine pin + cap build CPUs.
run_as_user "sed -i 's|engine-strict=true|engine-strict=false|g' '$NEW/.npmrc'" 2>/dev/null || true
run_as_user "grep -q 'cpus:' '$NEW/next.config.js' 2>/dev/null || sed -i 's|256000,|256000,\n    cpus: 6,|g' '$NEW/next.config.js'" 2>/dev/null || true

echo "Installing dependencies via pnpm (this might take a while)"
run_as_user "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    pnpm install --prefix '$NEW'
" >> "$log" 2>&1 || {
    echo "Dependency install failed. See $log"
    echo "Your old install is untouched. Restarting it..."
    run_as_user "rm -rf '$NEW'"
    systemctl_user start seerr 2>/dev/null || true
    exit 1
}

echo "Building seerr (this might take a while)"
run_as_user "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    pnpm --prefix '$NEW' build
" >> "$log" 2>&1 || {
    echo "Build failed. See $log"
    echo "Your old install is untouched. Restarting it..."
    run_as_user "rm -rf '$NEW'"
    systemctl_user start seerr 2>/dev/null || true
    exit 1
}
echo "Build succeeded."

# --- 3. Carry over data + config ---------------------------------------------
echo "Copying config and env.conf into the new build..."
if [[ -d "$APP/config" ]]; then
    run_as_user "mkdir -p '$NEW/config' && cp -a '$APP/config/.' '$NEW/config/'"
fi
if [[ -f "$APP/env.conf" ]]; then
    run_as_user "cp -a '$APP/env.conf' '$NEW/env.conf'"
fi

# --- 4. Swap directories -----------------------------------------------------
echo "Swapping new build into place (old kept at $OLD)..."
run_as_user "mv '$APP' '$OLD' && mv '$NEW' '$APP'"

# --- 5. Restart and verify ---------------------------------------------------
echo "Starting seerr service..."
systemctl_user start seerr

sleep 3
status="$(systemctl_user is-active seerr 2>/dev/null || echo unknown)"
echo ""
echo "=============================="
echo "  seerr update summary"
echo "=============================="
echo "  Service status : $status"
echo "  New build      : $APP  (from $FORK_URL${FORK_REF:+ @ $FORK_REF})"
echo "  Previous build : $OLD"
echo "  Data/config    : preserved ($APP/config, $APP/env.conf)"
echo ""
if [[ "$status" == "active" ]]; then
    echo "  Update complete. Verify in the browser, then remove the old build:"
    echo "    rm -rf '$OLD'"
else
    echo "  Service is NOT active. Check logs:"
    echo "    journalctl --user -u seerr -e"
    echo "    tail -n 50 $log"
    echo ""
    echo "  To roll back to the previous build:"
    echo "    systemctl --user stop seerr"
    echo "    rm -rf '$APP' && mv '$OLD' '$APP'"
    echo "    systemctl --user start seerr"
fi
echo "=============================="
echo ""
