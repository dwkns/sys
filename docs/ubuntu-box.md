# The Ubuntu box — dwkns-ubuntu

An old MacBook Pro running Ubuntu Server, on the tailnet at
`dwkns-ubuntu`. Account `admin`, with passwordless sudo. `sys` runs here,
but only does a subset — see below.

Written down because most of what is on it comes from vendor apt repositories
with their own signing keys, which `sys` deliberately does not set up. If the
disk dies, this is the rebuild list.

## What `sys sync` does here

1. Updates the repo in `~/.sys`.
2. Installs anything missing from `config/apt-packages`.
3. Copies the shared dotfiles (`.config/tmux/tmux.conf`,
   `.config/tmux/attach` and `.config/tmux/ssh.sh`) — not the Mac ones, which
   are all Homebrew, macOS paths and `duti` — and keeps a marked block in
   `~/.bashrc` that loads `ssh HOST tmux [NAME]`.
4. Applies SSH access from `config/ssh/access`.

No Homebrew, no mise, no macOS defaults. Install it with:

```bash
curl -fsSL https://raw.githubusercontent.com/dwkns/sys/master/bin/ssh-access | bash
```

## Installed by hand, from vendor repositories

Each needs its repository and signing key adding before the package exists.
Follow the vendor's current instructions rather than anything copied here —
these change, and a stale keyring command is worse than none.

- **Docker** — `docker-ce`, `docker-ce-cli`, `containerd.io`, plus the
  `buildx`, `compose` and `model` plugins. From Docker's own repository.
- **Tailscale** — `tailscale` and `tailscale-archive-keyring`, from
  Tailscale's repository. This is how every other machine reaches the box.
- **cloudflared** — Cloudflare's tunnel client, from their repository.

## Running on it

- Docker containers, both `restart: unless-stopped`; each stack belongs with
  the application it serves, not here:
  - `deploy-web-1`: Lift, from the image `lift-backend:latest`
    (compose files in `~/lift/deploy`).
  - `youpod-podcast-1`: YouPods (compose files in `~/youpod`).
- `cloudflared.service`: the tunnel that publishes the public routes (below).
- `tailscaled`: Tailscale.
- Cron at 03:30: `~/bin/lift-backup-to-github.sh`, the Lift backup. Lift's
  deploy installs that file and the crontab line.
- `openssh-server`, `avahi-daemon` and `ufw` (Ubuntu's firewall) are present
  from the base install.

## Its two routes

Like every other machine it should be reachable both over Tailscale
(`dwkns-ubuntu`) and on the home network (`dwkns-ubuntu.local`, which is
192.168.4.200). The second one silently did not work for a long time:
`/etc/avahi/avahi-daemon.conf` had `host-name=dwkns-mbp-unbutu` — a typo — so
avahi advertised the box under a misspelled name and the correct one never
resolved. The original file is kept beside it as
`avahi-daemon.conf.before-sys`. That file names the host explicitly, so a new
hostname needs a new `host-name=` line there too, then
`sudo systemctl restart avahi-daemon` — `hostnamectl` alone does not change
the `.local` name.

The box was `dwkns-mbp-ubuntu` until October 2026; `config/ssh/old-names`
keeps the old names working as aliases for a while.

The same file also has `allow-interfaces=enx9c69d3ac296c`, added 2026-11-02
(the file before it is `avahi-daemon.conf.bak-2026-11-02`). After that day's
reboot avahi heard its own name echoed back through Docker's bridge networks,
decided `dwkns-ubuntu` was taken, and advertised `dwkns-ubuntu-2.local`
instead: ssh on the home network broke, Tailscale still worked. Limiting avahi
to the Ethernet port stops the echo. To check, look for a name conflict:

```bash
journalctl -u avahi-daemon -b | grep "Host name"
```

`enx9c69d3ac296c` is the USB Ethernet adapter's name, taken from its hardware
address. A different adapter gets a different name, and this line (and the
firewall rules below) must change to match it; `ip -br link` shows the
current one.

If the `.local` name stops resolving again, that file is the first place to
look, then `systemctl is-active avahi-daemon`.

## Tailscale Serve and the public routes

Tailscale Serve, tailnet only:

- `https://dwkns-ubuntu.tail75564c.ts.net` (443) → Lift on `127.0.0.1:8000`.

Funnel is gone (removed 2026-11-02) and the tailnet policy no longer allows it.

Public routes go through the cloudflared tunnel named `lift`, configured in the
Cloudflare dashboard, not on the box:

- `lifts.tenkle.com` → `http://127.0.0.1:8000` (Lift)
- `youpods.tenkle.com` → `http://100.91.126.118:8080` (YouPods)

The Serve route is keyed by the tailnet name. After a rename, re-create it
(only it):

```bash
sudo tailscale serve reset && sudo tailscale serve --bg --https=443 http://127.0.0.1:8000
```

The tunnel's routes do not depend on the machine name, so a rename leaves
them alone.

## Security settings

**Firewall (ufw)**, active. Incoming is denied by default. Allowed: everything
on `tailscale0`; on the Ethernet port only 22/tcp (ssh) and
5353/udp (mDNS, for `dwkns-ubuntu.local`); and 41641/udp for Tailscale's
direct connections. To rebuild it:

```bash
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw allow in on enx9c69d3ac296c to any port 22 proto tcp
sudo ufw allow in on enx9c69d3ac296c to any port 5353 proto udp
sudo ufw allow 41641/udp && sudo ufw enable
```

**SSH**: `sys ssh harden tailnet`. Keys only from the home network; the
`admin` password is still accepted over Tailscale; X11 forwarding is off. The
laptop's screen is broken, so the password over Tailscale is the way back in
if every key is lost. Never run plain `sys ssh harden` here, and never turn on
Tailscale SSH: it takes over port 22 on the tailnet and ignores both keys and
passwords.

**Updates**: unattended upgrades reboot the box at 04:00 when an update needs
it (`/etc/apt/apt.conf.d/52unattended-reboot`), after the 03:30 backup.

**Turned off as unused**: ModemManager and open-vm-tools. `wpa_supplicant` is
left on on purpose.

**GitHub**: `gh` here uses a fine-grained token for `dwkns/YouPods` only, so
the box cannot push to `dwkns/sys`. Changes to sys are pushed from `dwkns-m5`
or `dwkns-mini`, then pulled here.

## Ordinary packages

Anything from Ubuntu's own repositories goes in `config/apt-packages`, one per
line, and installs itself on the next `sys sync` here. `tmux` is there now.
