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
3. Copies the shared dotfiles (`.config/tmux/tmux.conf` and
   `.config/tmux/attach`) — not the Mac ones, which are all Homebrew, macOS
   paths and `duti` — and keeps a marked block in `~/.bashrc` that attaches
   tmux on an interactive ssh login.
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

- A Docker container `deploy-web-1`, from the image `lift-backend:latest`.
  That stack belongs with the application it serves, not here.
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

The box was `dwkns-ubuntu` until October 2026; `config/ssh/old-names`
keeps that name and `ubuntu` working as aliases for a while.

If the `.local` name stops resolving again, that file is the first place to
look, then `systemctl is-active avahi-daemon`.

## Tailscale Serve and Funnel

- `https://dwkns-ubuntu.tail75564c.ts.net` (443) → Lift on `127.0.0.1:8000`.
- `https://dwkns-ubuntu.tail75564c.ts.net:8443` (Funnel, public) → youpod on
  `100.91.126.118:8080`.

Both are keyed by the tailnet name. After a rename, re-create them:

```bash
sudo tailscale serve reset && sudo tailscale serve --bg --https=443 http://127.0.0.1:8000 && sudo tailscale funnel --bg --https=8443 http://100.91.126.118:8080
```

## Ordinary packages

Anything from Ubuntu's own repositories goes in `config/apt-packages`, one per
line, and installs itself on the next `sys sync` here. `tmux` is there now.
