#!/bin/bash
# thx flyingsausages and swizzin team
# based on the seerr install script
# kavita — Kareadita/Kavita (self-contained .NET binary)

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
    echo "  - configure nginx so kavita is reachable at https://<host>/kavita"
    echo "  - add kavita to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install kavita without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/kavita.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/kavita.log"

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
function _kavita_install() {
    echo "Fetching latest Kavita release..."
    dlurl="$(curl -sS https://api.github.com/repos/Kareadita/Kavita/releases/latest \
        | jq -r '.assets[] | select(.name | test("kavita-linux-x64\\.tar\\.gz")) | .browser_download_url')"

    if [[ -z "$dlurl" ]]; then
        echo "Could not find kavita-linux-x64.tar.gz in latest release."
        exit 1
    fi

    echo "Downloading $dlurl..."
    run_as_user "wget '$dlurl' -q -O '$target_home/kavita.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed"
        exit 1
    }

    # Tarball extracts to a Kavita/ subdirectory
    run_as_user "mkdir -p '$target_home/kavita' && tar --strip-components=1 -C '$target_home/kavita' -xzf '$target_home/kavita.tar.gz' && rm '$target_home/kavita.tar.gz'" >> "$log" 2>&1 || {
        echo "Extraction failed"
        exit 1
    }
    run_as_user "chmod +x '$target_home/kavita/Kavita'"
    echo "Kavita extracted."
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    _check_linger
    run_as_user "mkdir -p '$target_home/.config/systemd/user' '$target_home/.install'"

    KAVITA_PORT=$(_port 1000 18000)

    # Write appsettings.json before first run so Kavita picks up our port.
    # config/ dir is inside the Kavita install dir.
    run_as_user "mkdir -p '$target_home/kavita/config'"
    tmp_cfg="$(mktemp)"
    cat > "$tmp_cfg" << EOF
{
  "TokenKey": "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)",
  "Port": $KAVITA_PORT,
  "IpAddresses": "",
  "BaseUrl": "/",
  "Cache": 75
}
EOF
    install -m 0600 -o "$target_user" -g "$target_user" "$tmp_cfg" "$target_home/kavita/config/appsettings.json"
    rm -f "$tmp_cfg"

    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=Kavita Service
Wants=network-online.target
After=network-online.target
[Service]
Type=exec
Restart=on-failure
WorkingDirectory=%h/kavita
ExecStart=%h/kavita/Kavita
[Install]
WantedBy=default.target
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/kavita.service"
    rm -f "$tmp_unit"

    systemctl_user daemon-reload
    systemctl_user enable --now -q kavita
    run_as_user "touch '$target_home/.install/.kavita.lock'"

    if $SUDO_MODE; then
        echo "kavita listening on 0.0.0.0:$KAVITA_PORT (nginx will expose it at /kavita)"
    else
        echo "kavita is up and running on http://$(hostname -f):$KAVITA_PORT"
    fi
}

# --- Nginx + swizzin dashboard (root only) -----------------------------------
function _nginx() {
    if [[ -z "${KAVITA_PORT:-}" ]]; then
        echo "KAVITA_PORT not set, skipping nginx config."
        return 1
    fi

    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic              \"What's the password?\";
    auth_basic_user_file    ${htpasswd_file};"
    fi

    local hostname
    hostname="$(hostname -f)"
    read -r -p "  Hostname for kavita redirect [$hostname]: " hostname_input
    [[ -n "$hostname_input" ]] && hostname="$hostname_input"

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/kavita.conf << EOF
location /kavita {
    return 301 http://${hostname}:${KAVITA_PORT}/;
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. kavita reachable at https://$(hostname -f)/kavita"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/kavita.conf."
        return 1
    fi
}

function _dashboard() {
    icon_dir="/opt/swizzin/static/img/apps"
    icon_url="https://raw.githubusercontent.com/Flawkee/swizzin.apps/main/kavita.png"
    if curl -fsSL -o "$icon_dir/kavita.png" "$icon_url" 2>>"$log"; then
        echo "Icon installed to $icon_dir/kavita.png"
    else
        echo "Could not download kavita icon from $icon_url (continuing without custom icon)."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class kavita_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class kavita_meta:
    name = "kavita"
    pretty_name = "Kavita"
    baseurl = "/kavita"
    systemd = "kavita"
    img = "kavita"
    runas = "user"
EOF
        echo "Appended kavita_meta to $profiles"
    else
        echo "kavita_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.kavita.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _remove() {
    systemctl_user disable --now kavita 2>/dev/null || true
    sleep 2
    run_as_user "rm -rf '$target_home/kavita' '$target_home/.config/systemd/user/kavita.service' '$target_home/.install/.kavita.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/kavita.conf
        if nginx -t >> "$log" 2>&1; then
            systemctl reload nginx
        fi

        rm -f /install/.kavita.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class kavita_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        rm -f /opt/swizzin/static/img/apps/kavita.png
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
    lock="$target_home/.install/.kavita.lock"
    if [[ ! -f "$lock" ]]; then
        echo "kavita is not installed. Run 'install' first."
        return
    fi

    port=""
    cfg="$target_home/kavita/config/appsettings.json"
    if [[ -f "$cfg" ]]; then
        port="$(jq -r '.Port' "$cfg" 2>/dev/null)"
    fi

    svc_status="$(systemctl_user is-active kavita 2>/dev/null || echo "unknown")"

    nginx_conf="/etc/nginx/apps/kavita.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="http://$(hostname -f):${port:-?}  (nginx /kavita redirects here)"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}"
    fi

    panel_lock="/install/.kavita.lock"
    if [[ -f "$panel_lock" ]] && grep -q "^class kavita_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  kavita installation summary"
    echo "=============================="
    echo "  Service name  : kavita"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo "  Config        : $target_home/kavita/config/"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status kavita"
    echo "    systemctl --user restart kavita"
    echo "    journalctl --user -u kavita -f"
    echo "=============================="
    echo ""
}

echo "Welcome to the kavita installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install kavita"
echo "uninstall = Completely removes kavita"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            clear
            _kavita_install
            _service
            if $SUDO_MODE; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  nginx + swizzin dashboard setup — please read before continuing"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  The following will be configured:"
                echo ""
                echo "  1. /etc/nginx/apps/kavita.conf"
                echo "     - Redirects https://<host>/kavita → http://$(hostname -f):$KAVITA_PORT/"
                echo "     - Simple redirect: no path rewriting, kavita runs directly on its port."
                echo ""
                echo "  2. /opt/swizzin/core/custom/profiles.py"
                echo "     - Appends kavita_meta so kavita appears in the swizzin panel sidebar."
                echo ""
                echo "  3. /install/.kavita.lock + panel restart"
                echo ""
                read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                if [[ "$nginx_confirm" == "yes" ]]; then
                    _nginx
                    _dashboard
                else
                    echo "  Skipped. kavita is running on http://$(hostname -f):$KAVITA_PORT"
                    echo "  You can re-run the installer and choose 'install' again to set it up later."
                fi
                echo ""
            fi
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
