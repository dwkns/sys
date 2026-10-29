# system-config

macOS setup: one command on a new machine, one command to keep it in sync.

## New machine

```bash
curl -fsSL https://raw.githubusercontent.com/dwkns/system-install/master/install.sh | bash
```

Installs Homebrew and everything in the `Brewfile`, copies dotfiles into place,
installs language versions with mise, downloads and verifies MailExporter
from its GitHub release, builds Paywall Down from its private repo and installs
it in `/Applications`, installs App Store apps, and applies macOS defaults. It finishes by printing the
handful of steps that need a human (signing into things, granting Full Disk
Access, logging out).

It asks for your password once, at the start, and never again during the run.
It turns on Remote Login and Screen Sharing, so you can `ssh` or `vnc://` in once it finishes.
It names the Mac `dwkns-<type>-<chip>` — for example `dwkns-mbp-m1` or
`dwkns-mini-m4` — unless you type something else within fifteen seconds. When
it finishes it opens a fresh shell with the new config loaded.

## Day to day

| Command | What it does |
|---|---|
| `sys sync` | Pull the latest config and apply it here: apps, dotfiles, Dock, desktop colour, SSH access, Paywall Down |
| `sys sync all` | The same here, then on every machine this one may log into, one after another |
| `sys push` | Save this machine's config into the repo and push |
| `sys doctor` | Check everything is installed and signed in |
| `sys ai` | A generated brief of the whole repo, for an AI picking it up cold |
| `sys ssh` | The machines sys manages, and whether each is reachable right now |
| `sys ssh all` | The same, plus anything hand-written in `~/.ssh/config` |
| `sys ssh man` | The manual |
| `sys ssh NAME` | Log in and attach a tmux session no other connection is using |
| `sys ssh harden` | Keys only on this machine — optional; passwords stay on otherwise |
| `sys nas` | The NAS: how to reach it, its disk, shares and Tailscale |
| `sys nas open` | Open the NAS's web page |
| `sys tailscale up` | Turn Tailscale on here, then on every machine this one may log into |
| `sys net` | List the network shares; `sys net dwkns-nas` mounts one |
| `sys hostname` | Set the computer name (asks, or `sys hostname my-mac`) |
| `sys extras` | Install optional extras (Office, Xcode, duckdb) |
| `sys remove` | Undo everything setup installed (asks first; `--dry-run` previews) |
| `sys setup` | Re-run setup; safe to repeat |

Add `--dry-run` to any of them to see what would happen, or `--force` to
`sys sync` to reinstall and rebuild everything even when nothing has changed.

Full documentation: `man sys`

## SSH between machines

One file in the repo says who may log in where:

```
# config/ssh/access
# machine            account   may be logged into from
dwkns-m5         dwkns     dwkns-mini
dwkns-mini        dwkns     dwkns-m5  dwkns-ubuntu
dwkns-ubuntu     admin     dwkns-m5  dwkns-mini
```

Every `sys sync` applies it. On each machine that means: make its own key if
it has none, share its public keys into the repo (the user key under
`config/ssh/keys/`, the machine's own host key under `config/ssh/hostkeys/` —
the one thing sync commits by itself; both are safe to publish and always the
machine's own), install the keys of the machines let in here, pin every other
machine's host key, and write an alias for each. So `ssh mini` just works,
as the right account, with no password: over Tailscale from anywhere, or over
the home network with Tailscale off. A machine that is not the one it claims
to be is refused. The aliases never offer a password; plain `ssh user@host`
still does. Server-side passwords stay on unless you run `sys ssh harden`.

Private keys never leave the machine that made them. Nothing here ever types
a password or copies a key by hand.

**A new Mac** needs nothing beyond the installer. Its key is shared on the first
sync; if the machine has no GitHub login yet, sync signs you in through `gh`
once, in the browser, and carries on. Add the new machine to `config/ssh/access` on
any machine and `sys push`; every other machine follows on its next sync.

**A renamed machine** keeps answering to its old names for a while: list them
against its new name in `config/ssh/old-names`, and sync writes them as extra
aliases.

**A device that only logs in** — Termius on the phone — needs no line of its
own. Put its public key in `config/ssh/keys/NAME.pub`, add NAME to the "from"
column of each machine it may reach, and `sys push`.

**A machine that cannot run sys** — the Synology NAS has no git — is listed in
`config/ssh/no-sys`. It only ever receives logins, so every machine that syncs
and is allowed in there writes its `authorized_keys` over SSH instead, and
`sys sync all` does not try to run `sys` on it. One key has to be put there by
hand first, or there would be no way in to write the file with.

**The Ubuntu box** gets the same repo and a `sys` command that does only the
repo update and SSH access. Once, to set up:

```bash
curl -fsSL https://raw.githubusercontent.com/dwkns/system-install/master/bin/ssh-access | bash
```

After that it is `sys sync` there too, whenever a machine is added.

## Turning Tailscale back on

`sys tailscale up` turns Tailscale on here, then on every machine this one may
log into. Here first: away from home the tailnet is the only route to the rest.
At home the aliases fall back to `NAME.local`, so a machine with Tailscale off
is still reachable — get into any one machine and the others can follow. From
the phone, the mini is the best way in: it may log into all the others.

The NAS is only checked. Its Tailscale needs `sudo`, which asks for a password
there, so the run prints the command for you to type instead.

## Sessions that survive a dropped connection

Every interactive ssh login lands in tmux: `sys ssh mini`, plain
`ssh mini`, or a terminal app on your phone. Close the lid, lose signal, or
quit the app: the session keeps running on the machine, and the next login
picks it up exactly where you left it. `Ctrl-b d` detaches on purpose and
leaves you at a plain shell.

A login takes a session that no other connection is using, or starts a new
one. So each terminal tab has a session of its own, and a tab whose connection
dropped gets its own back — it is the one with nobody attached. Two tabs that
drop together may swap. Scripted ssh (`sys sync all`, `scp`, editors) has no
terminal and never lands in tmux.

The rule is `dotfiles/.config/tmux/attach`, run from the end of
`dotfiles/.zshrc` on the Macs and from a marked block sync keeps in
`~/.bashrc` on the Ubuntu box. The config is `dotfiles/.config/tmux/tmux.conf`.
Both reach the Ubuntu box as shared dotfiles.

## Starting over

`sys remove` removes everything setup installed — Homebrew and its packages,
mise toolchains, the dotfiles it copied, editor config, and the Dock — without
erasing macOS. SSH and Screen Sharing are left alone, so a headless machine
stays reachable.

```bash
sys remove --dryrun   # list what would be removed, change nothing
sys remove            # list it, then ask before removing
```

Then run the installer again. Because it leaves your account and remote access
alone, a headless machine stays reachable throughout.

**Do not use Erase All Content and Settings on a headless Mac.** It reboots
into Setup Assistant, which needs a physical keyboard and display — you would
lose remote access until someone attaches a screen.

## Layout

```
Brewfile                     apps and CLI tools
Brewfile.optional            optional extras (`sys extras`)
bin/set-dock                 writes the Dock in one atomic operation (run by sync)
macos.sh                     macOS defaults
install.sh                   new-machine entry point
bin/sys                      the only command
man/man1/sys.1               man page (`man sys`)
AGENTS.md                    how it all works, and how to change it (for AI assistants)
lib/common.sh                colours, logging, helpers
lib/sync.sh                  mirrors config between repo and system
lib/setup.sh                 brew, mise, App Store, macOS, the Dock
lib/ssh.sh                   SSH keys, access and aliases from config/ssh/access (run by sync)
lib/tailscale.sh             `sys tailscale up` — Tailscale on here and on the machines this one can log into
bin/ssh-access               the one command for a machine that does not run sys
bin/ssh-reach                Tailscale name or NAME.local? the aliases ask this
bin/ai-brief                 `sys ai` — the repo explained, generated from the repo
config/ssh/access            who may log in where, and as which account
config/ssh/no-sys            machines that cannot run sys; their access is pushed to them
config/net                   network shares for `sys net`
config/nas                   the NAS's name and web page, for `sys nas`
config/apt-packages          packages for the Ubuntu box, installed by sync there
docs/ubuntu-box.md           how the Ubuntu box was built, and what sys does there
docs/nas.md                  the Synology: accounts, shares, Time Machine, Tailscale
config/ssh/keys/             each machine's public key, shared by sys sync
dotfiles/                    copied into ~
config/mas-apps.txt          App Store app IDs
config/input                 keyboard and trackpad, applied on every sync
config/desktop-colour        solid desktop colour, applied by sync when it changes
config/dock                  the Dock, captured by push and applied by sync when it changes
config/ssh/hostkeys/         each machine's sshd host key, pinned everywhere by sync
config/terminfo/             terminal descriptions (Ghostty) every machine learns, so ssh sessions work
config/sublime-config/       copied into Sublime's User dir
config/cursor/               copied into Cursor's User dir
config/cursor-extensions.txt Cursor extensions, installed by `sys setup`
colors/                      .clr palettes -> ~/Library/Colors
```

## How syncing works

`lib/sync.sh` holds a table of repo directory to system directory:

```
dotfiles              -> ~
colors                -> ~/Library/Colors
config/sublime-config -> ~/Library/Application Support/Sublime Text/User
config/cursor         -> ~/Library/Application Support/Cursor/User
```

**The contents of each repo directory are the manifest.** To track a new file,
put it in the right directory — there's no list to update. To stop tracking one,
delete it.

`sys sync` treats the repo as the source of truth and overwrites. Before
replacing a system file whose contents differ, it copies the old version to
`.drift/` and says so — so a local edit you forgot to `sys push` is never lost,
but a legitimate update from the repo still installs. `.drift/` is overwritten
each run rather than accumulating. Git is the history; there is no `backups/`.

## Languages

mise owns Ruby, Node and Python. Global versions are in
`dotfiles/.config/mise/config.toml`; override per project with a local
`mise.toml`. Python packages and virtualenvs go through `uv`.

