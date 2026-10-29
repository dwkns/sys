# Working on this repo

Notes for an AI assistant (or a human) picking this up cold. `README.md` says what
the system does for its user; this file says how it works inside, and how to
change it without breaking a machine.

Repo: `~/.system-config` on every machine. Remote:
`https://github.com/dwkns/system-install.git`, branch `master`.

---

## 1. Ground rules

**The GitHub repo is public.** Never commit a secret. No licence files, no
tokens, no `~/.codex/auth.json`, no `~/.config/gh`, no `~/.claude.json`, no
private keys. `.gitignore` blocks `.ssh/`, `id_*`, `*.pem`, `known_hosts*` and
`*.sublime_license` so a private key cannot be added by accident. The only keys
in the repo are public halves under `config/ssh/keys/` and
`config/ssh/hostkeys/`, which are meant to be published.

**Never type the user's password.** Anything needing `sudo` interactively is
theirs to run. Scripts get sudo through the askpass helper (section 5), which
the user feeds once at the start of a run.

**Verify, don't assume.** Most bugs in this repo's history were confident
claims that turned out false: a setting that was never written, a step that
"succeeded" because its errors went to `/dev/null`, a dry run that stamped
itself as done. Read the value back after writing it. Say plainly when
something was not tested.

**Shell constraints.**
- macOS ships bash 3.2. No `declare -A`, no `${var^^}`, no `readarray`.
- `lib/common.sh` is also sourced by `.zshrc`, so it must stay valid in *zsh*
  as well: no bash-only arrays in it, no `read -p`, and remember zsh does not
  word-split unquoted variables.
- `install.sh` and `bin/ssh-access` run under `curl … | bash`, where **stdin is
  the script itself**. Never `exec </dev/tty` there — bash then tries to read
  the rest of the script from the keyboard and hangs. Redirect per command.
- `set -euo pipefail` is on in `bin/sys` and the libraries. A function whose
  failure is acceptable must end with `return 0` or be called with `|| true`.

**Output style.** Terse, lowercase-ish, one idea per line. `doing/ok/note/warn/
error` from `lib/common.sh` give the glyphs. Emoji in headers and tables must be
double-width (📦 🔑 🩺); narrow ones (🛠 🛡 ⚠️) break column alignment.

**Colour means something.** Four colours, defined once in `lib/common.sh` and
mirrored in `bin/ssh-hosts` (Python, so it cannot source them):

| | |
|---|---|
| `GREY` | supporting copy — explanations, hints, what to do next |
| `GREEN` | good — done, working, reachable, installed |
| `ORANGE` | off, but expected — the consequence of a choice, and we know it |
| `RED` | bad — failed, missing, unexplained; worth looking at |
| `WHITE` | the subject — titles, machine and file names, commands to type |

`ORANGE` is the one that takes judgement. Use it only when the code *knows*
why something is not working and that reason is the user's own switch: the
tailnet routes while `tailscale status` says the daemon is off. The same row
goes `RED` when Tailscale is running, because then it is a real fault. Never
guess — if the cause is unknown, it is `RED`.

**Marking commands.** Never colour a command by hand inside a message. Put it
in `{{double braces}}` and `doing/ok/note/warn/error` render it white,
returning the sentence to its own colour afterwards (`hl` in `lib/common.sh`):

```bash
note "Add a line for it, {{sys push}}, {{sys sync}}"
```

Braces, not backticks: messages live in double quotes, where backticks would
run the command instead of printing it. Hand-built `printf` output — the
doctor table, `sys net`, `bin/ssh-hosts` — has to wrap commands itself, and
must restore the surrounding colour after `RESET`.

There is no sixth colour. `DIM`, `BOLD`, `CYAN` and `YELLOW` still exist as
aliases onto these so nothing breaks, but new code should use the four names.
A command the user could type is always `WHITE`, whatever state it is in —
state is carried by the status next to it, not by dimming the command.

---

## 2. Entry points

| Path | Role |
|---|---|
| `install.sh` | One-line installer for a new Mac. Waits for Xcode CLT, clones the repo, `exec bin/sys setup --yes` |
| `bin/sys` | The only command. Dispatcher plus the body of every command |
| `bin/ssh-access` | One-line installer for a machine that is not a Mac (the Ubuntu box) |
| `lib/common.sh` | Colours, logging, `run`, `confirm`, `ask_timeout`, `header` |
| `lib/sync.sh` | Repo ⇄ system file mirroring, git plumbing, GitHub device login |
| `lib/setup.sh` | Homebrew, mise, App Store, macOS settings, sudo, MailExporter, Paywall Down, naming, removal |
| `lib/ssh.sh` | Keys, `authorized_keys`, host-key pinning, aliases, `sys sync all` |
| `macos.sh` | `defaults write` lines applied by setup and by sync |
| `bin/set-dock` | Rebuilds the Dock atomically from `config/dock` |
| `bin/dump-dock` | Captures the current Dock into `config/dock` (run by `sys push`) |
| `bin/set-desktop-colour` | Solid desktop colour via JXA, with verification |
| `bin/ssh-hosts` | `sys ssh` — machines from `config/ssh/access`, both routes probed in parallel |
| `bin/ssh-reach` | Is NAME answering on port 22 within 2s? Used by the ssh aliases |
| `lib/net.sh` | `sys net` — network shares from `config/net`, mounted through Finder |
| `lib/nas.sh` | `sys nas` — the NAS's reachability, disk, shares and Tailscale, from `config/nas` |
| `lib/tailscale.sh` | `sys tailscale up` — Tailscale on here, then on every machine this one may log into |
| `bin/ai-brief` | `sys ai` — this file's companion, generated: commands, config, machines, state |
| `docs/ubuntu-box.md` | How the Ubuntu box was built — vendor repos `sys` does not manage |
| `docs/nas.md` | The Synology — accounts, shares, Time Machine, Tailscale, and their failure modes |
| `man/man1/sys.1` | Man page. Keep in step with behaviour |

Config lives in `config/`, dotfiles in `dotfiles/`, palettes in `colors/`.

Two gitignored directories hold local state:
- `.state/` — stamps recording which once-only steps have run (section 5).
- `.drift/` — copies of system files that sync replaced because they differed.

---

## 3. What each command does

### `sys setup`
1. `update_self` — `git pull --ff-only --autostash`, then `restart_if_updated`
   re-execs sys if the pull changed `bin/` or `lib/` (guarded by `SYS_RESTARTED`).
2. Prints the heads-up text, then `acquire_sudo` — the single password prompt.
3. Eleven numbered steps via `step()`, which records failures and carries on:
   packages → dotfiles → languages → Cursor extensions → MailExporter → App
   Store → Remote Login → SSH key and access → Paywall Down → Screen Sharing
   → macOS defaults. Paywall Down is after SSH so a new machine has had its
   chance to sign in to GitHub. `TOTAL=11` is hard-coded; update it if you
   add a step.
4. Then the once-only bits: hostname prompt, Dock, input settings, desktop
   colour, default terminal.
5. Verdict, `sys doctor`, `print_manual_steps`, `request_reload`. If run from
   the installer it `exec`s a fresh login shell.

### `sys sync`
1. Fetch, then reconcile in whichever direction is needed: behind → `pull
   --ff-only`; ahead → push; diverged → `pull --rebase --autostash` then push;
   real conflict → `die` with instructions.
2. `restart_if_updated`, so a fix to sync runs as the new version.
3. Not macOS? `ssh_apply` and exit — that is all sync does on Linux.
4. `brew_changed` = Brewfile fingerprint ≠ `.state/brewfile` (or `--force`).
5. `sync_install` (dotfiles), `apply_input_settings` (every sync), `ssh_apply
   quiet`, `install_paywall_down quiet`, `run_once dock`, `run_once desktop`.
6. Nothing changed → "Already up to date — nothing to apply" and stop.
   Otherwise show Brewfile changes, `install_packages` if needed,
   `apply_macos_defaults`, `request_reload`.
7. `sys sync all` then runs `sys sync` over ssh on every machine this one may
   log into (`ssh_sync_others`).

**Sync never commits the state of this machine.** Capturing local state is
`sys push`. The one exception is this machine's own public SSH keys, committed
by path in `ssh_share_key`.

### `sys push`
`sync_backup` (system → repo for files the repo already tracks), dump Cursor
extensions, `bin/dump-dock`, then `git add -A`, commit "Update config files",
`push_repo`.

### `sys tailscale up`
`tailscale_up_all` in `lib/tailscale.sh`. This machine first, then the targets
`ssh_sync_others` would pick (every machine whose "from" column names this one),
skipping any that `bin/ssh-reach` cannot find on either route. One POSIX `sh`
script, `ts_script`, does the work: it runs locally through `sh -s`, and on
each target over one bounded ssh login (`timed 60`), with the script on stdin
so nothing needs quoting. It finds the Mac app's CLI, the Synology package's,
or `tailscale` on PATH; uses `sudo -n` off the Mac; and answers with one word
on its last line, which `ts_report` turns into output. `tailscale up` is run
with no flags on purpose: with none it reconnects with the saved settings,
whereas any flag makes it demand every non-default flag (the Ubuntu box
advertises an exit node). No-sys machines get `check` mode only — interactive
sudo is the user's to run — and the printed command for them.

### `sys doctor`
Read-only table: tools present, mise versions, App Store reachable, SSH key
made/shared and how many machines are let in, whether sshd is keys-only, Dock
matches config, desktop colour, whether Paywall Down is in `/Applications`,
repo clean. Must never block — network calls go
through `with_timeout`.

### `sys remove`
Undoes what setup installed (Homebrew and its packages, mise toolchains, copied
dotfiles, editor config, Dock and Finder defaults) *without* erasing macOS, and
deliberately leaves the user account, SSH and Screen Sharing alone so a headless
machine stays reachable. Shows the plan, then asks. `--dry-run` stops after the
plan.

---

## 4. The SSH subsystem

One file drives it: **`config/ssh/access`**.

```
# machine            account   may be logged into from
dwkns-mbp-m5         dwkns     dwkns-mini-m1
dwkns-mini-m1        dwkns     dwkns-mbp-m5  dwkns-mbp-ubuntu
```

Column 1 is the machine's hostname, column 2 the account to log in as, the rest
are the machines allowed in. `ssh_apply` runs on every sync and does five things
on the local machine:

1. `ssh_make_key` — ed25519 at `~/.ssh/id_ed25519`, no passphrase, made locally
   and never copied anywhere.
2. `ssh_share_key` — copies this machine's public user key to
   `config/ssh/keys/NAME.pub` and its sshd host key to
   `config/ssh/hostkeys/NAME.pub`, commits **those paths only**, and pushes. If
   the machine has no GitHub login, `push_repo` signs in once with a device code
   in the browser.
3. `ssh_install_access` — rewrites a marked block in `~/.ssh/authorized_keys`
   holding the keys of the machines the access file lets in here. Keys outside
   the markers are left alone.
4. `ssh_write_known_hosts` — `~/.ssh/known_hosts_sys`, built from
   `config/ssh/hostkeys/`, so first contact needs no "are you sure?" and an
   impostor is refused. It lives outside `~/.ssh/config.d/`, which ssh would
   read as config.
5. `ssh_write_aliases` — `~/.ssh/config.d/sys`, with `Include config.d/*`
   prepended to `~/.ssh/config`. Each machine gets two routes: a `Match … exec
   bin/ssh-reach` line preferring the Tailscale name, falling back to a `Host`
   block using `NAME.local`. Both share one `HostKeyAlias`, so one pinned key
   covers both. The aliases use keys only and never offer a password.

Aliases drop the shared `dwkns-` prefix when every machine has it, so `ssh
mini-m1` works.

**Machines that cannot run sys** are listed in `config/ssh/no-sys` (the
Synology: no git, so no repo). `ssh_push_access` writes their
`authorized_keys` over SSH from every machine that syncs and is allowed in
there, and `ssh_sync_others` skips them. Two things to know if you touch it:
`ssh` re-parses the remote command through a shell, so the keys travel as one
base64 blob rather than a multi-line argument; and the remote end only rewrites
the text between the markers, leaving hand-added keys alone. Bootstrapping
still needs one key put there by hand.

`install_terminfo` also runs here, compiling `config/terminfo/*` (Ghostty's
`xterm-ghostty`) so ssh sessions from Ghostty do not land on "unknown terminal".

### Adding a machine

**A new Mac.**

1. On the new Mac, run the installer:
   `curl -fsSL https://raw.githubusercontent.com/dwkns/system-install/master/install.sh | bash`
   Setup names it `dwkns-<type>-<chip>` (15-second prompt to override), turns on
   Remote Login and Screen Sharing, makes its SSH key and, on the first sync
   that can reach GitHub, commits `config/ssh/keys/NAME.pub` and
   `config/ssh/hostkeys/NAME.pub`.
2. On any machine, add a line to `config/ssh/access` for the new machine, and
   add its name to the "from" column of every machine it should be able to
   reach. Then `sys push`.
3. `sys sync` on each other machine — or `sys sync all` from one of them — so
   each installs the new machine's key and writes its alias.
4. Check with `sys ssh` (lists aliases and flags stale ones) and `ssh NAME`.

Steps 2–4 are the whole job for an assistant asked to "add a machine": edit one
file, push, sync. Nothing is copied by hand.

**A machine that does not run sys** (the Ubuntu box):

```bash
curl -fsSL https://raw.githubusercontent.com/dwkns/system-install/master/bin/ssh-access | bash
```

It clones the repo, symlinks `sys` into `~/.local/bin`, and runs `sys sync`,
which on Linux does the repo update and SSH access only. If that machine cannot
push (no `gh`), `ssh_share_key` prints its public keys and asks for them to be
pasted in on a Mac instead of leaving untracked files behind.

**A device that only logs in** (Termius on the phone, `dwkns-iphone`): its
public key goes in `config/ssh/keys/NAME.pub` by hand, and NAME in the "from"
column. No line of its own — column 1 is only for machines that are logged
into, and `ssh_prefix`, the aliases and `sys ssh` read column 1 only.

**Removing a machine:** delete its line in `config/ssh/access`, remove its name
from every "from" column, delete `config/ssh/keys/NAME.pub` and
`config/ssh/hostkeys/NAME.pub`, `sys push`, then sync everywhere. The managed
block in `authorized_keys` shrinks on the next sync.

**`sys ssh harden`** writes `/etc/ssh/sshd_config.d/00-sys-keys-only.conf` and
restarts sshd, turning password logins off. It refuses unless at least one key
is already let in, so a headless machine cannot lock itself out. Optional, and
per machine.

---

## 5. Mechanisms worth knowing before you edit anything

**`run_once <name> <fingerprint> <cmd…>`** (`lib/setup.sh`). The stamp
`.state/<name>` holds the fingerprint of the config the step last succeeded
with. Change the config and the step runs again. Two rules the hard way:
- the stamp is written **only on success**, so a half-finished step retries;
- a dry run must never write a stamp, or the real run skips the step.

**`fingerprint file…`** is `cat "$@" | shasum -a 256`. Dock and desktop stamps
hash the config *and the script that applies it*, so fixing a bug in the script
re-runs it on machines that already had a stamp. Do the same for any new
once-only step.

**Sync targets** (`lib/sync.sh`) map a repo directory to a system directory:

```
dotfiles              -> ~
colors                -> ~/Library/Colors
config/sublime-config -> ~/Library/Application Support/Sublime Text/User
config/cursor         -> ~/Library/Application Support/Cursor/User
```

The *contents* of the repo directory are the manifest: add a file to track it,
delete it to stop. `sync_install` copies repo → system, skipping identical
files, stashing anything that differs into `.drift/` first. `sync_backup` copies
system → repo for files the repo already tracks.

**`acquire_sudo`** asks for the password once, validates it with `sudo -S -v`,
writes a 0700 askpass helper in a private temp dir, exports `SUDO_ASKPASS`,
keeps the login fresh in a background loop, and clears everything on exit via
`trap`. Homebrew honours `SUDO_ASKPASS` (it passes `-A`), which is why the run
does not stop for a password mid-install. Use `sudo_run` for anything needing
root.

**Shell reload.** `sys` is a child process and cannot reload its parent shell.
The `sys()` wrapper in `dotfiles/.aliases` passes `SYS_RELOAD_FILE`; touching
that file (`request_reload`) makes the wrapper `exec zsh` afterwards.

**`push_repo`** pushes commits that already exist, and if the failure is a
missing login it runs a GitHub device-code sign-in (`github_device_login` in
`lib/sync.sh`) rather than stalling at a `Username:` prompt.

**Environment:** `ROOT_DIR`, `DRY_RUN`, `ASSUME_YES`, `FORCE`, `SYS_RESTARTED`,
`SYS_FROM_INSTALLER`, `SYS_RELOAD_FILE`, `MACHINE_NAME_PREFIX`,
`MAIL_EXPORTER_REPO`.

---

## 6. Recipes

**A Homebrew package.** Add a `brew "x"` or `cask "x"` line to `Brewfile`,
commit, push. Every machine installs it on the next `sys sync`, because the
Brewfile fingerprint no longer matches `.state/brewfile`. Optional things go in
`Brewfile.optional` (`sys extras`). `brew bundle` runs with `--no-upgrade` —
keep it: without it a sync silently upgrades every app on the machine. Never
add `--cleanup`: it would uninstall anything installed by hand.

**A dotfile.** Put it in `dotfiles/` at the path it should have under `~`, then
`sys push`. Editing `dotfiles/.aliases` in the repo does nothing on this machine
until `sys sync` copies it into `~` (and reloads the shell). Editing `~/.aliases`
directly works immediately but needs `sys push` to be saved. Do not do both: the
repo wins and the home copy lands in `.drift/`.

**A macOS default.** Add a `defaults write` line to `macos.sh` with a comment
saying what it does and what the values mean. Only include settings that differ
from Apple's default. Find the key by inspecting the settings pane:
`plutil -convert json -o - /System/Library/ExtensionKit/Extensions/<pane>.appex/Contents/Resources/Localizable.loctable`
and `strings -a` on the pane binary or nib usually names it (that is how
`EnableStandardClickToShowDesktop` and Safari's `IncludeDevelopMenu` were
found). Check the current value with `defaults read` before and after. The file
ends by killing `cfprefsd Dock Finder SystemUIServer`; some settings still need
a logout.

**A keyboard or trackpad setting.** These live in `config/input`, not
`macos.sh`, because they are applied on *every* sync:
`domain|key|type|value`, where `trackpad` expands to both trackpad domains and
`currentHost:X` means `defaults -currentHost`. `apply_input_settings` reads each
domain once in Python, compares type-aware, writes only what differs and stays
silent when nothing does. Keep it silent — it runs constantly.

**The Dock.** Edit `config/dock` (one app path per line, `$HOME/Downloads` under
`# Folders`), or arrange the Dock by hand and run `sys push`, which captures it
via `bin/dump-dock`. Other machines rebuild it on their next sync because the
fingerprint changed. Apply it locally with `ROOT_DIR=$PWD bin/set-dock`. There is
no `sys dock` command.

**App Store apps** go in `config/mas-apps.txt` (`id # Name`), optional ones in
`config/mas-apps-optional.txt`. `mas account` no longer exists — use `mas list`.

**Cursor extensions** live in `config/cursor-extensions.txt`, refreshed by
`sys push`. VS Code syncs through its own account and is not tracked.

**The desktop colour** is `config/desktop-colour` — four floats, RGBA 0–1.
`bin/set-desktop-colour` writes a solid PNG, sets it through JXA, then polls
until macOS reports it applied. Re-run it with
`rm .state/desktop && sys sync`, or `sys sync --force`.

**A network share.** Add a line to `config/net`: `name | url`.
The url must name the share (`smb://user@host/Share`) or Finder stops to ask
which one. `sys net NAME` hands the url to `open`, then waits for the volume to
appear rather than trusting that `open` returned. Passwords are never handled
here: the Keychain items Finder writes are locked to Finder and NetAuthAgent,
so `smbutil` and `mount_smbfs` are refused and would fall back to prompting.
Two things learned on the Synology: macOS keeps **one SMB session per server**,
so a share that another account is barred from reports "the share does not
exist" rather than a permission error while you are signed in as someone else;
and a stuck Finder dialog blocks every later mount attempt silently.

**Tab completion.** `dotfiles/.config/zsh/completions/_sys` completes the
sub-commands, and reads `config/net` and `config/ssh/access` live, so a new
line in either completes without touching the completion file. `.zshrc` keeps
`compinit -C` for fast shell start-up and rebuilds the cache only when `_sys`
is newer than `~/.zcompdump` — with `-i`, because Homebrew ships a
group-writable `_ghostty` and a plain `compinit` aborts on it, leaving the
shell with no completions at all. Test it for real in a pty (a
non-interactive zsh returns at the top of `.zshrc`).

**Paywall Down.** `install_paywall_down` in `lib/setup.sh`, called from
`sys setup` and, quietly, from `sys sync`. It clones
`https://github.com/dwkns/paywall-down.git` into `~/Developer/paywall-down`
(or fast-forwards a clean checkout) and builds the scheme `pwd (macOS)` with
`MACOSX_DEPLOYMENT_TARGET=12.0` on the command line. The project still says
10.14, which Xcode 27 rejects; the repo is not edited to change that. Signing
is the project's Automatic signing, team `LD2427W529` — do not pass a
different identity, and do not install a `.app` built on another Mac. The
built app is copied to `/Applications/Paywall Down.app` (same place as
MailExporter) and launched so Safari registers
`com.dwkns.paywall-down.Extension`. A stamp in `.state/paywall-down` holds the
commit that was installed; a re-run with the same commit does not rebuild.
Needs full Xcode, a GitHub login that can read the private repo, and an Apple
ID in Xcode that can sign for that team. "Allow unsigned extensions" in Safari
is not set from here.

**A package for the Ubuntu box.** Add it to `config/apt-packages`. `sys sync`
there installs whatever is missing — no stamp, because `dpkg-query` is cheap
and it then self-heals if something is removed. Vendor-repo software (Docker,
cloudflared, Tailscale) is out of scope by design; `docs/ubuntu-box.md` records
it instead.

**A dotfile for every OS, not just the Macs.** Add its path to
`SHARED_DOTFILES` in `lib/setup.sh`. A full `sync_install` on Linux would drop
`.zshrc` and friends there, and those assume Homebrew and macOS.

**Anything that runs a command over ssh.** A non-interactive ssh session gets a
bare PATH, so Homebrew binaries look missing — `sys ssh NAME` wraps its remote
command in `bash -lc` for exactly this reason, and it silently handed back a
plain shell instead of tmux until it did. Test it in a pty and check what you
actually landed in.

**tmux on ssh login.** `dotfiles/.config/tmux/attach` picks the session: the
first one with no client attached, else a new one. Three callers: the hook at
the end of `dotfiles/.zshrc` (Macs), the marked block `install_bashrc_hook`
keeps in `~/.bashrc` (Linux), and `ssh_connect`. The hooks need an interactive
shell, `$SSH_CONNECTION` set, `$TMUX` empty and a tty on stdin and stdout, so
`sys sync all`, `scp` and editors probing the shell never land in tmux. Keep
those guards if you touch it: a login that hangs in tmux breaks every scripted
ssh call.

**A new command or setup step.** Add the `case` branch in `bin/sys`, bump
`TOTAL` if it is a numbered setup step, and update **both** `README.md` and
`man/man1/sys.1` plus the usage text. Those three drift easily; check them
whenever behaviour changes.

---

## 7. Testing

- `bash -n file.sh` after every edit. It catches syntax errors, but **not** a
  Python heredoc rewrite that matched nothing — always assert a replacement
  actually happened, and re-read the region.
- `--dry-run` / `DRY_RUN=1` on any command. Make sure new code paths respect it:
  no writes, no downloads, no stamps.
- Read settings back after writing them (`defaults read`, `bin/set-dock`
  verifies its own write, `bin/set-desktop-colour --check`).
- `sys doctor` after anything structural.
- To re-test a once-only step: `rm .state/<name>` or `sys sync --force`.
- Testing on another machine happens over ssh (`ssh mbp-m5 'sys sync'`). Note
  that a sandboxed tool without macOS "Local Network" permission cannot reach
  `*.local` at all — the symptom is "No route to host" from a command that works
  in the user's own terminal.

---

## 8. Mistakes already made here

Kept as a list because each one cost a debugging session.

- `brew bundle` without `--no-upgrade` upgraded 16 unrelated apps.
- A dry run wrote a "done" stamp, so the real run skipped the step.
- Dock errors were sent to `/dev/null`, so a failed Dock reported success.
- Per-app `dockutil` calls raced cfprefsd and lost entries; `bin/set-dock`
  writes the whole array once instead.
- Stamps that hashed only config skipped a *fixed script* on another machine;
  they now hash the script too.
- MailExporter's version check would have downgraded a newer local build —
  hence `version_ge`.
- The desktop colour "passed" a test that set the colour it already had. Test a
  change, not a no-op. The JXA bridge returns counts as strings, and
  `setDesktopImageURL` applies asynchronously.
- `NSTableViewDefaultSizeMode 1` was removed on the false belief that 1 meant
  medium. It means small.
- Safari's preferences live in its sandbox container; writing them needs Full
  Disk Access for the terminal, and Safari rewrites the file when it quits.
- Finder has no global default *window size*: size is stored per folder in that
  folder's `.DS_Store`. `FXPreferredViewStyle` only sets the view (`clmv`,
  `Nlsv`, `icnv`, `glyv`), and folders with their own saved view keep it.

---

- **A frozen 1Password SSH agent hung every login, with nothing on screen.**
  A `Host *` `IdentityAgent` line (and `SSH_AUTH_SOCK`) pointed ssh at it;
  `IdentitiesOnly yes` does not stop ssh asking the agent first; and
  `ConnectTimeout` only bounds the TCP connect, not authentication. Now sys's
  hosts carry `IdentityAgent none` (they use their own on-disk key), every
  unattended ssh call goes through `timed` in `lib/common.sh`, and `sys
  doctor` reports the agent when anything points ssh at it.

## 9. Keeping docs in step

`README.md` (what it does), `man/man1/sys.1` (reference), this file (how it
works and how to change it). A behaviour change should update whichever of the
three describe it, in the same commit.

Commit messages are one plain sentence saying what changed, with a body when the
reason is not obvious. When an AI assistant commits, add the trailer its harness
asks for.
