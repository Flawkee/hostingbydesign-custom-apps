# swizzin.apps

Custom install scripts for apps not offered by swizzin's panel out of the box, targeting shared seedbox environments.

Most apps run as rootless systemd `--user` services. **Netdata** is an exception — it installs system-wide and runs as a system service; its script always requires `sudo`.

Each script handles download, build/config, and a systemd service. Run with `sudo` to also configure an nginx reverse proxy and add the app to the swizzin dashboard.

## Available scripts

| Script | App | nginx path | Notes |
| --- | --- | --- | --- |
| [seerr.sh](seerr.sh) | Seerr | `/seerr` | Builds from source via pnpm. No native base URL support — nginx redirects `/seerr` to the app's direct port. |
| [sonarr4k.sh](sonarr4k.sh) | Sonarr 4K | `/sonarr4k` | Second Sonarr instance for 4K content. Requires Sonarr already installed. |
| [radarr4k.sh](radarr4k.sh) | Radarr 4K | `/radarr4k` | Second Radarr instance for 4K content. Requires Radarr already installed. |
| [bazarr4k.sh](bazarr4k.sh) | Bazarr 4K | `/bazarr4k` | Second Bazarr instance for 4K content. Requires Bazarr already installed. |
| [flaresolverr.sh](flaresolverr.sh) | FlareSolverr | N/A | Downloads pre-built binary. No nginx or dashboard support — runs as a simple API service on localhost. |
| [netdata.sh](netdata.sh) | Netdata | `/netdata` | System-wide monitoring. Installs via official kickstart.sh. **Always requires sudo.** |

## Usage

Replace `<script>` with the filename (e.g. `seerr.sh`).

**Remote install — user level only (no nginx/dashboard):**
```bash
bash <(curl -sL -H 'Cache-Control: no-cache' "https://github.com/Flawkee/swizzin.apps/raw/main/<script>")
```

**Remote install — full (nginx reverse proxy + swizzin dashboard):**
```bash
sudo bash -c "$(curl -sL -H 'Cache-Control: no-cache' 'https://github.com/Flawkee/swizzin.apps/raw/main/<script>')"
```

> The `-H 'Cache-Control: no-cache'` header bypasses GitHub's CDN cache and ensures you always get the latest version of the script.

Each installer prompts for a menu action:

| Option | Description |
| --- | --- |
| `show` | Print current status: service state, port, URL, nginx and swizzin panel setup |
| `install` | Configure and start the app |
| `upgrade` | Available on Sonarr 4K, Radarr 4K, Bazarr 4K, and Netdata. Regenerates systemd service (4K variants) or upgrades the binary (Netdata). |
| `secure` | Available on Netdata only. Claims the agent to Netdata Cloud and enables Bearer Token Protection. |
| `uninstall` | Stop service, remove files, and (if sudo) remove nginx config and dashboard entry |
| `exit` | Quit without doing anything |

When run with `sudo`, `install` will pause after the app is up and ask whether to proceed with nginx + dashboard setup, explaining what it will write before making any changes.

## How nginx integration works

| App | Approach |
| --- | --- |
| Sonarr 4K, Radarr 4K, Bazarr 4K | App natively serves under its `UrlBase` — nginx proxies straight through with `proxy_redirect off`. No path rewriting needed. |
| Netdata | No native subpath support. nginx uses a regex capture group (`~ /netdata/(?<ndpath>.*)`) to strip the prefix and proxy to `http://127.0.0.1:19999/$ndpath` — Netdata's documented reverse-proxy pattern. |
| Seerr | No native base URL support. nginx issues a `return 301` redirect from `/seerr` to the app's direct `http://host:port`. |
| FlareSolverr | No nginx integration. Listens on `localhost:8191` (or a custom port) for internal API use. Intended as a backend service, not exposed through nginx. |

## Service management

**User-level apps** (Seerr, Sonarr 4K, Radarr 4K, Bazarr 4K, FlareSolverr):
```bash
systemctl --user status <app>
systemctl --user restart <app>
journalctl --user -u <app> -f
```

**System-level apps** (Netdata):
```bash
systemctl status netdata
systemctl restart netdata
journalctl -u netdata -f
```

**Logs:**
- User apps: `~/.logs/<app>.log` (e.g. `~/.logs/seerr.log`, `~/.logs/flaresolverr.log`)
- Netdata: `/var/log/netdata/`

**Config:**
- User apps: `~/.config/<App>/` (e.g. `~/.config/Sonarr4k/`, `~/.config/bazarr4k/`, `~/flaresolverr/env.conf`)
- Netdata: `/etc/netdata/`

**Binaries:**
- 4K variants (Sonarr 4K, Radarr 4K, Bazarr 4K): shared from base installs (`/opt/Sonarr/`, `/opt/Radarr/`, `/opt/bazarr/`)
- Seerr: built in place at `~/seerr/`
- FlareSolverr: pre-built at `~/flaresolverr/`
- Netdata: system-wide via official kickstart
