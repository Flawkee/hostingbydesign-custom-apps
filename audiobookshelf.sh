#!/bin/bash
# thx flyingsausages and swizzin team
# based on the seerr install script
# audiobookshelf — advplyr/audiobookshelf (Node.js)

# --- Privilege detection -----------------------------------------------------
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

if ! $SUDO_MODE; then
    echo ""
    echo "Not running with sudo."
    echo "Without sudo this installer cannot:"
    echo "  - configure nginx so audiobookshelf is reachable at https://<host>/audiobookshelf"
    echo "  - add audiobookshelf to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install audiobookshelf without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/audiobookshelf.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/audiobookshelf.log"

# --- Helpers to run things as the target user --------------------------------
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

# Ensure systemd --user services survive logout.
_check_linger() {
    if loginctl show-user "$target_user" 2>/dev/null | grep -q 'Linger=yes'; then
        return 0
    fi
    echo "Linger is not enabled for $target_user — enabling now..."
    loginctl enable-linger "$target_user"
    echo "Linger enabled for $target_user."
}

# --- Install steps -----------------------------------------------------------
function _deps() {
    if [[ ! -d "$target_home/.nvm" ]]; then
        echo "Installing nvm/node..."
        run_as_user 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/refs/heads/master/install.sh | bash' >> "$log" 2>&1
        echo "nvm installed."
    else
        echo "nvm already installed."
    fi
    run_as_user '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install --lts
    ' >> "$log" 2>&1 || {
        echo "node failed to install"
        exit 1
    }
    echo "Node LTS installed."
}

function _audiobookshelf_install() {
    echo "Fetching latest audiobookshelf release..."
    dlurl="$(curl -sS https://api.github.com/repos/advplyr/audiobookshelf/releases/latest 2>/dev/null | jq -r .tarball_url)"

    if [[ -z "$dlurl" ]] || [[ "$dlurl" == "null" ]]; then
        echo "No releases found, using main branch..."
        dlurl="https://github.com/advplyr/audiobookshelf/archive/refs/heads/main.tar.gz"
    fi

    echo "Downloading source..."
    run_as_user "wget '$dlurl' -q -O '$target_home/audiobookshelf.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed"
        exit 1
    }
    run_as_user "mkdir -p '$target_home/audiobookshelf' && tar --strip-components=1 -C '$target_home/audiobookshelf' -xzf '$target_home/audiobookshelf.tar.gz' && rm '$target_home/audiobookshelf.tar.gz'" >> "$log" 2>&1
    echo "Source extracted."

    echo "Installing dependencies..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        cd '$target_home/audiobookshelf'
        npm install
    " >> "$log" 2>&1 || {
        echo "npm ci failed"
        exit 1
    }
    echo "Dependencies installed."

    echo "Building client (this might take a while)..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        cd '$target_home/audiobookshelf'
        npm run client
    " >> "$log" 2>&1 || {
        echo "Client build failed"
        exit 1
    }
    echo "Client built."
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    _check_linger
    run_as_user "mkdir -p '$target_home/.config/systemd/user' '$target_home/.install' '$target_home/.config/audiobookshelf/metadata' '$target_home/audiobooks' '$target_home/podcasts'"

    node_path="$(run_as_user 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; which node' | tail -n1)"

    ABS_PORT=$(_port 1000 18000)

    tmp_env="$(mktemp)"
    cat > "$tmp_env" << EOF
PORT=$ABS_PORT
HOST=127.0.0.1
CONFIG_PATH=$target_home/.config/audiobookshelf
METADATA_PATH=$target_home/.config/audiobookshelf/metadata
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_env" "$target_home/audiobookshelf/env.conf"
    rm -f "$tmp_env"

    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=audiobookshelf Service
Wants=network-online.target
After=network-online.target
[Service]
EnvironmentFile=%h/audiobookshelf/env.conf
Type=exec
Restart=on-failure
WorkingDirectory=%h/audiobookshelf
ExecStart=$node_path index.js
[Install]
WantedBy=default.target
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/audiobookshelf.service"
    rm -f "$tmp_unit"

    systemctl_user daemon-reload
    systemctl_user enable --now -q audiobookshelf
    run_as_user "touch '$target_home/.install/.audiobookshelf.lock'"

    if $SUDO_MODE; then
        echo "audiobookshelf listening on 127.0.0.1:$ABS_PORT (nginx will expose it at /audiobookshelf)"
    else
        echo "audiobookshelf is up and running on http://$(hostname -f):$ABS_PORT/audiobookshelf"
    fi
}

# --- Nginx + swizzin dashboard (root only) -----------------------------------
function _nginx() {
    if [[ -z "${ABS_PORT:-}" ]]; then
        echo "ABS_PORT not set, skipping nginx config."
        return 1
    fi

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/audiobookshelf.conf << EOF
location /audiobookshelf {
    proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto  \$scheme;
    proxy_set_header Host               \$http_host;
    proxy_set_header Upgrade            \$http_upgrade;
    proxy_set_header Connection         "upgrade";
    proxy_http_version                  1.1;
    proxy_pass                          http://127.0.0.1:${ABS_PORT};
    proxy_redirect                      http:// https://;
    client_max_body_size                10240M;
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. audiobookshelf reachable at https://$(hostname -f)/audiobookshelf"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/audiobookshelf.conf."
        return 1
    fi
}

function _dashboard() {
    icon_dir="/opt/swizzin/static/img/apps"
    icon_url="https://raw.githubusercontent.com/Flawkee/swizzin.apps/main/audiobookshelf.png"
    if curl -fsSL -o "$icon_dir/audiobookshelf.png" "$icon_url" 2>>"$log"; then
        echo "Icon installed to $icon_dir/audiobookshelf.png"
    else
        echo "Could not download audiobookshelf icon from $icon_url (continuing without custom icon)."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class audiobookshelf_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class audiobookshelf_meta:
    name = "audiobookshelf"
    pretty_name = "Audiobookshelf"
    baseurl = "/audiobookshelf"
    systemd = "audiobookshelf"
    img = "audiobookshelf"
    runas = "user"
EOF
        echo "Appended audiobookshelf_meta to $profiles"
    else
        echo "audiobookshelf_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.audiobookshelf.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _upgrade() {
    lock="$target_home/.install/.audiobookshelf.lock"
    if [[ ! -f "$lock" ]]; then
        echo "audiobookshelf is not installed. Run 'install' first."
        return 1
    fi

    echo "Stopping audiobookshelf service..."
    systemctl_user stop audiobookshelf 2>/dev/null || true

    env_conf="$target_home/audiobookshelf/env.conf"
    tmp_env="$(mktemp)"
    if [[ -f "$env_conf" ]]; then
        cp "$env_conf" "$tmp_env"
        echo "env.conf saved."
    else
        echo "Warning: env.conf not found — service config will be lost."
    fi

    echo "Removing old source..."
    run_as_user "rm -rf '$target_home/audiobookshelf'"

    echo "Fetching latest audiobookshelf release..."
    dlurl="$(curl -sS https://api.github.com/repos/advplyr/audiobookshelf/releases/latest 2>/dev/null | jq -r .tarball_url)"
    if [[ -z "$dlurl" ]] || [[ "$dlurl" == "null" ]]; then
        echo "No releases found, using main branch..."
        dlurl="https://github.com/advplyr/audiobookshelf/archive/refs/heads/main.tar.gz"
    fi
    run_as_user "wget '$dlurl' -q -O '$target_home/audiobookshelf.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed"
        return 1
    }
    run_as_user "mkdir -p '$target_home/audiobookshelf' && tar --strip-components=1 -C '$target_home/audiobookshelf' -xzf '$target_home/audiobookshelf.tar.gz' && rm '$target_home/audiobookshelf.tar.gz'" >> "$log" 2>&1
    echo "Source extracted."

    if [[ -s "$tmp_env" ]]; then
        install -m 0644 -o "$target_user" -g "$target_user" "$tmp_env" "$target_home/audiobookshelf/env.conf"
        echo "env.conf restored."
    fi
    rm -f "$tmp_env"

    echo "Installing dependencies..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        cd '$target_home/audiobookshelf'
        npm install
    " >> "$log" 2>&1 || { echo "npm ci failed"; return 1; }

    echo "Building client (this might take a while)..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        cd '$target_home/audiobookshelf'
        npm run client
    " >> "$log" 2>&1 || { echo "Client build failed"; return 1; }
    echo "Client built."

    systemctl_user daemon-reload
    systemctl_user start audiobookshelf
    echo "audiobookshelf upgraded and restarted."
}

function _remove() {
    systemctl_user disable --now audiobookshelf 2>/dev/null || true
    sleep 2
    run_as_user "rm -rf '$target_home/audiobookshelf' '$target_home/.config/audiobookshelf' '$target_home/.config/systemd/user/audiobookshelf.service' '$target_home/.install/.audiobookshelf.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/audiobookshelf.conf
        if nginx -t >> "$log" 2>&1; then
            systemctl reload nginx
        fi

        rm -f /install/.audiobookshelf.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class audiobookshelf_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        rm -f /opt/swizzin/static/img/apps/audiobookshelf.png
        systemctl restart panel 2>/dev/null || true
    fi
}

# --- Entry point -------------------------------------------------------------
echo 'This is unsupported software. You will not get help with this, please answer `yes` if you understand and wish to proceed'
if [[ -z ${eula} ]]; then
    read -r eula
fi

if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
else
    echo "Proceeding with installation"
fi

function _show() {
    lock="$target_home/.install/.audiobookshelf.lock"
    if [[ ! -f "$lock" ]]; then
        echo "audiobookshelf is not installed. Run 'install' first."
        return
    fi

    port=""
    env_conf="$target_home/audiobookshelf/env.conf"
    if [[ -f "$env_conf" ]]; then
        port="$(grep -E '^PORT=' "$env_conf" | cut -d= -f2)"
    fi

    svc_status="$(systemctl_user is-active audiobookshelf 2>/dev/null || echo "unknown")"

    nginx_conf="/etc/nginx/apps/audiobookshelf.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/audiobookshelf"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}/audiobookshelf"
    fi

    panel_lock="/install/.audiobookshelf.lock"
    if [[ -f "$panel_lock" ]] && grep -q "^class audiobookshelf_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  audiobookshelf installation summary"
    echo "=============================="
    echo "  Service name  : audiobookshelf"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo "  Config dir    : $target_home/.config/audiobookshelf"
    echo "  Metadata dir  : $target_home/.config/audiobookshelf/metadata"
    echo "  Audiobooks    : $target_home/audiobooks  (configure in app)"
    echo "  Podcasts      : $target_home/podcasts    (configure in app)"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status audiobookshelf"
    echo "    systemctl --user restart audiobookshelf"
    echo "    journalctl --user -u audiobookshelf -f"
    echo "=============================="
    echo ""
}

echo "Welcome to the audiobookshelf installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install audiobookshelf"
echo "upgrade   = Upgrade audiobookshelf (preserves config and data)"
echo "uninstall = Completely removes audiobookshelf"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            clear
            _deps
            _audiobookshelf_install
            _service
            if $SUDO_MODE; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  nginx + swizzin dashboard setup — please read before continuing"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  The following will be configured:"
                echo ""
                echo "  1. /etc/nginx/apps/audiobookshelf.conf"
                echo "     - Reverse proxies https://<host>/audiobookshelf → http://127.0.0.1:$ABS_PORT"
                echo "     - WebSocket (socket.io) headers included for real-time features."
                echo "     - client_max_body_size 10240M for large audiobook uploads."
                echo ""
                echo "  2. /opt/swizzin/core/custom/profiles.py"
                echo "     - Appends audiobookshelf_meta so it appears in the swizzin panel sidebar."
                echo ""
                echo "  3. /install/.audiobookshelf.lock + panel restart"
                echo ""
                read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                if [[ "$nginx_confirm" == "yes" ]]; then
                    _nginx
                    _dashboard
                else
                    echo "  Skipped. audiobookshelf is running on http://$(hostname -f):$ABS_PORT"
                    echo "  You can re-run the installer and choose 'install' again to set it up later."
                fi
                echo ""
            fi
            break
            ;;
        "upgrade")
            _upgrade
            break
            ;;
        "uninstall")
            _remove
            break
            ;;
        "exit")
            break
            ;;
        *)
            echo "Unknown Option."
            ;;
    esac
done
exit
