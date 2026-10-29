#!/usr/bin/env bash
# Everything that turns a bare Mac into a working one.

source "${ROOT_DIR:-$HOME/.sys}/lib/common.sh"
source "${ROOT_DIR:-$HOME/.sys}/lib/sync.sh"

install_homebrew() {
  has_cmd brew && return 0
  doing "Installing Homebrew"
  # With the password helper in place it can run unattended, instead of
  # stopping to say "Press RETURN" and asking for the password itself.
  if [[ -n "${SUDO_ASKPASS:-}" ]]; then
    run env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
}

# Turn on a sharing service by talking to launchd directly — systemsetup
# needs Full Disk Access on current macOS, which a fresh terminal does not
# have — and make sure this user is allowed to use it.
#   enable_service <label> <launchd name> <plist> <port> <access group> <how to reach it>
enable_service() {
  local label="$1" name="$2" plist="$3" port="$4" group="$5" reach="$6"
  if nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1; then
    note "$label: already on"
  else
    doing "Turning on $label"
    run sudo_run launchctl enable "system/$name"
    run sudo_run launchctl bootstrap system "$plist" 2>/dev/null || true
  fi

  # If the service is limited to particular users, make sure this one is included.
  if dseditgroup -o read "$group" >/dev/null 2>&1 &&
     ! dseditgroup -o checkmember -m "$USER" "$group" >/dev/null 2>&1; then
    run sudo_run dseditgroup -o edit -a "$USER" -t user "$group"
  fi

  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  local i
  for i in 1 2 3 4 5; do
    nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1 && break
    sleep 1
  done
  if nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1; then
    ok "$label on — $reach"
  else
    warn "$label did not come on — System Settings ▸ General ▸ Sharing ▸ $label"
    return 1
  fi
}

enable_remote_login() {
  enable_service "Remote Login" com.openssh.sshd /System/Library/LaunchDaemons/ssh.plist 22 \
    com.apple.access_ssh "ssh $USER@$(scutil --get LocalHostName 2>/dev/null).local"
}

enable_screen_sharing() {
  enable_service "Screen Sharing" com.apple.screensharing /System/Library/LaunchDaemons/com.apple.screensharing.plist 5900 \
    com.apple.access_screensharing "vnc://$(scutil --get LocalHostName 2>/dev/null).local"
}

# ── One password for the whole run ───────────────────────────────────────────
# A cached sudo login keeps getting lost: Homebrew's installer clears it when
# it exits, and casks run sudo of their own. So instead of caching, ask once,
# check it, and give sudo a helper that answers for you (SUDO_ASKPASS —
# Homebrew passes -A whenever it is set). The password sits in a private temp
# file for the length of this run only, and is removed when sys exits.
acquire_sudo() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  [[ -n "${SUDO_ASKPASS:-}" ]] && return 0
  if ! { true </dev/tty; } 2>/dev/null; then
    warn "No terminal to ask for a password — sudo may prompt later"
    return 0
  fi

  SUDO_DIR="$(mktemp -d)" || return 1
  chmod 700 "$SUDO_DIR"
  local pw tries=0
  while (( tries < 3 )); do
    printf '  🔑  Your Mac password — asked once, for the whole run: ' >/dev/tty
    IFS= read -rs pw </dev/tty || pw=""
    printf '\n' >/dev/tty
    # printf is a shell builtin, so the password never appears in ps output.
    if printf '%s\n' "$pw" | sudo -S -v 2>/dev/null; then
      ( umask 077; printf '%s\n' "$pw" > "$SUDO_DIR/pw" )
      printf '#!/bin/sh\ncat "%s"\n' "$SUDO_DIR/pw" > "$SUDO_DIR/askpass"
      chmod 700 "$SUDO_DIR/askpass"
      pw=""
      export SUDO_ASKPASS="$SUDO_DIR/askpass"
      # Keep the login fresh, and restore it quietly if something clears it.
      ( while kill -0 "$$" 2>/dev/null; do sudo -A -v >/dev/null 2>&1; sleep 50; done ) &
      SUDO_KEEPALIVE=$!
      trap release_sudo EXIT
      trap 'release_sudo; exit 130' INT TERM
      ok "Password accepted — you won't be asked again"
      return 0
    fi
    tries=$((tries + 1))
    warn "That password didn't work ($tries of 3)"
  done
  rm -rf "$SUDO_DIR"
  die "Could not get administrator access."
}

release_sudo() {
  [[ -n "${SUDO_KEEPALIVE:-}" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null
  [[ -n "${SUDO_DIR:-}" ]] && rm -rf "$SUDO_DIR"
  SUDO_KEEPALIVE="" SUDO_DIR=""
  unset SUDO_ASKPASS
  return 0
}

# sudo through the helper when there is one, plain sudo otherwise.
sudo_run() {
  if [[ -n "${SUDO_ASKPASS:-}" ]]; then sudo -A "$@"; else sudo "$@"; fi
}

# sys is a child process, so it cannot reload the shell it was started from.
# The sys function in ~/.aliases passes SYS_RELOAD_FILE; touching it asks that
# function to reload the shell once sys has finished.
request_reload() {
  [[ -n "${SYS_RELOAD_FILE:-}" ]] && : > "$SYS_RELOAD_FILE"
  return 0
}

# Homebrew belongs to whoever installed it. Delete that account and make a new
# one (even with the same name, it gets a new user id) and brew refuses to
# update: "/opt/homebrew is not writable". Hand it back to this user first.
reclaim_homebrew() {
  local prefix=/opt/homebrew
  [[ -d "$prefix" ]] || return 0
  # Top level only: that is what brew checks, and a full walk takes seconds.
  [[ -n "$(find "$prefix" -maxdepth 1 ! -user "$(id -u)" -print -quit 2>/dev/null)" ]] || return 0
  doing "Homebrew belongs to another account — giving it to $(id -un)"
  run sudo_run chown -R "$(id -un):admin" "$prefix"
}

install_packages() {
  install_homebrew
  reclaim_homebrew
  doing "Installing packages from Brewfile"
  # --no-upgrade: install what is missing, but never upgrade what is already
  # here. Without it a sync can cascade into upgrading every app on the
  # machine, which is not what "apply the latest config" should mean.
  run brew bundle install --no-upgrade --file "$ROOT_DIR/Brewfile" || return 1
  # Record what was installed, so sync knows this Brewfile is satisfied here
  # and can show what changed next time. Not on a dry run.
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$ROOT_DIR/.state" && fingerprint "$ROOT_DIR/Brewfile" > "$ROOT_DIR/.state/brewfile"
  cp "$ROOT_DIR/Brewfile" "$ROOT_DIR/.state/Brewfile.last"
}

# Packages from config/apt-packages, for machines that use apt. Installs only
# what is missing, so it is quick enough to check on every sync and self-heals
# if something was removed. Vendor-repo software (Docker, cloudflared,
# Tailscale) is deliberately not managed here — see docs/ubuntu-box.md.
install_apt_packages() {
  local file="$ROOT_DIR/config/apt-packages"
  [[ -r "$file" ]] || return 0
  has_cmd apt-get || return 0

  local want missing=""
  want="$(sed 's/#.*//' "$file" | awk 'NF{print $1}')"
  local p
  for p in $want; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing="$missing $p"
  done
  [[ -n "$missing" ]] || return 0

  doing "Installing:$missing"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: apt-get install$missing"; return 0; fi
  sudo_run apt-get update -qq || warn "apt-get update failed — trying the install anyway"
  # shellcheck disable=SC2086
  sudo_run apt-get install -y -qq $missing >/dev/null || { warn "Could not install:$missing"; return 1; }
  ok "Installed:$missing"
}

# The few dotfiles that make sense on any machine. A full sync_install would
# drop .zshrc and friends on the Ubuntu box, and those are all Homebrew, macOS
# paths and duti.
SHARED_DOTFILES=".config/tmux/tmux.conf .config/tmux/attach"
install_shared_dotfiles() {
  local rel src dst n=0
  for rel in $SHARED_DOTFILES; do
    src="$ROOT_DIR/dotfiles/$rel"; dst="$HOME/$rel"
    [[ -f "$src" ]] || continue
    cmp -s "$src" "$dst" && continue
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$src" "$dst" || continue
    n=$((n + 1))
  done
  (( n > 0 )) && doing "Installed $n shared dotfile(s)"
  return 0
}

# Linux only: the Macs get the same hook at the end of dotfiles/.zshrc, but
# ~/.bashrc here is Ubuntu's own file, so sys keeps just a marked block in it.
# The block is rewritten when it differs; everything outside it is left alone.
BASHRC_MARK_START="# >>> sys: tmux on ssh login >>>"
BASHRC_MARK_END="# <<< sys: tmux on ssh login <<<"
install_bashrc_hook() {
  local rc="$HOME/.bashrc" block outside new
  block="$BASHRC_MARK_START
# Added by sys sync (~/.sys). An interactive ssh login lands in a
# tmux session no other connection is using. Rule: ~/.config/tmux/attach
if [[ \$- == *i* && -n \"\$SSH_CONNECTION\" && -z \"\$TMUX\" && -t 0 && -t 1 && -r ~/.config/tmux/attach ]]; then
  bash ~/.config/tmux/attach
fi
$BASHRC_MARK_END"
  outside=""
  [[ -f "$rc" ]] && outside="$(awk -v s="$BASHRC_MARK_START" -v e="$BASHRC_MARK_END" \
      '$0==s{in_=1;next} $0==e{in_=0;next} !in_' "$rc")"
  outside="$(printf '%s\n' "$outside" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"   # trim trailing blanks
  new="$(printf '%s\n\n%s\n' "$outside" "$block" | sed '/./,$!d')"
  [[ -f "$rc" && "$(cat "$rc")" == "$new" ]] && return 0
  doing "Adding the tmux login hook to ~/.bashrc"
  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: write the marked block in ~/.bashrc"; return 0; }
  printf '%s\n' "$new" > "$rc.tmp" && mv "$rc.tmp" "$rc"
  return 0
}

# mise reads dotfiles/.config/mise/config.toml, so dotfiles must be synced first.
install_languages() {
  has_cmd mise || { warn "mise not installed; skipping languages"; return 0; }
  doing "Installing language versions with mise"
  run mise install
}

install_app_store_apps() {
  local file="$ROOT_DIR/config/mas-apps.txt"
  [[ -r "$file" ]] || return 0
  has_cmd mas || { warn "mas not installed; skipping App Store apps"; MAS_SKIPPED=1; return 0; }

  # The App Store needs you signed in, so never assume. Default to no, so an
  # unattended run walks past it rather than stalling on a password prompt.
  if ! ask_timeout 15 n "Install App Store apps? (needs you signed in)"; then
    note "Skipped — run {{sys setup}} again once you are signed in."
    MAS_SKIPPED=1
    return 0
  fi

  local installed
  if ! installed="$(mas list 2>/dev/null)"; then
    warn "Can't read the App Store — sign in, then run {{sys setup}} again"
    MAS_SKIPPED=1
    return 0
  fi

  doing "Installing App Store apps"
  note "If you are asked for your password here, it is the App Store installer."
  local line id
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    id="${line%%[^0-9]*}"
    [[ -n "$id" ]] || continue
    if printf '%s\n' "$installed" | awk -v id="$id" '$1==id{f=1} END{exit !f}'; then
      note "already installed: $(printf '%s' "$line" | sed 's/^[0-9]*[[:space:]]*#*[[:space:]]*//')"
    else
      run mas install "$id"
    fi
  done < "$file"
}


# Cursor has no Settings Sync (unlike VS Code, which syncs via your account),
# so its extensions are tracked here and installed explicitly.
install_editor_extensions() {
  local file="$ROOT_DIR/config/cursor-extensions.txt"
  [[ -r "$file" ]] || return 0
  has_cmd cursor || { warn "cursor CLI not on PATH; skipping its extensions"; return 0; }

  local have ext missing=0
  have="$(cursor --list-extensions 2>/dev/null)"
  while IFS= read -r ext; do
    [[ -z "$ext" || "$ext" == \#* ]] && continue
    printf '%s' "$have" | grep -qix "$ext" && continue
    run cursor --install-extension "$ext" --force >/dev/null 2>&1
    missing=$((missing + 1))
  done < "$file"
  [[ "$missing" -gt 0 ]] && doing "Installed $missing Cursor extension(s)" || note "Cursor extensions: up to date"
  return 0
}

# Run a step at most once per machine, per version of its config.
#
#   run_once <name> <fingerprint> <command...>
#
# The stamp holds the fingerprint of the config the step last succeeded with,
# so editing that config makes the step run again. The stamp is written ONLY
# on success, so a half finished install retries rather than skipping.
run_once() {
  local name="$1" fp="$2"; shift 2
  local stamp="$ROOT_DIR/.state/$name"
  if [[ "${FORCE:-0}" != "1" && -e "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$fp" ]]; then
    [[ "${RUN_ONCE_NOTE:-0}" == "1" ]] && note "$name: already done — skipping ({{sys sync --force}} redoes it)"
    return 0
  fi
  if "$@"; then
    # A dry run must not leave a "done" stamp, or the real run skips the step.
    [[ "${DRY_RUN:-0}" == "1" ]] || { mkdir -p "$(dirname "$stamp")" && printf '%s\n' "$fp" >"$stamp"; }
  else
    note "$name: not done yet, will try again next run"
  fi
  return 0
}

# Fingerprint a file so a change to it re-triggers its once-only step.
# One file gives the same digest as before, so existing stamps stay valid.
fingerprint() { { cat "$@" 2>/dev/null || true; } | shasum -a 256 | cut -d' ' -f1; }

# Rebuilds the Dock from config/dock. bin/set-dock writes the whole Dock in
# one go: separate per-app calls race against cfprefsd and silently lose
# entries. Errors are shown, never swallowed.
configure_dock() {
  local setter="$ROOT_DIR/bin/set-dock"
  [[ -x "$setter" ]] || { warn "bin/set-dock missing; skipping the Dock"; return 1; }
  [[ -r "$ROOT_DIR/config/dock" ]] || return 1

  doing "Setting up the Dock"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    ROOT_DIR="$ROOT_DIR" "$setter" --dry-run || return 1
  else
    ROOT_DIR="$ROOT_DIR" "$setter" || { error "Could not set the Dock"; return 1; }
  fi
}

# Remove a path completely. Several ~/Library folders carry a
# "group:everyone deny delete" ACL, so the directory itself cannot be removed
# even by its owner — empty it instead.
wipe() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  rm -rf "$p" 2>/dev/null && return 0
  find "$p" -mindepth 1 -delete 2>/dev/null
  rmdir "$p" 2>/dev/null || true
}

# Undoes everything setup installed, so a machine can be tested from scratch
# WITHOUT erasing macOS. Never touches the user account, SSH or Screen Sharing,
# so a headless machine stays reachable.
#
# Shows the plan, then asks. DRY_RUN=1 shows the plan and stops.
remove_everything() {
  local dry="${DRY_RUN:-0}" brew_f=0 brew_c=0
  local -a plan=()

  has_cmd brew && {
    brew_f=$(brew list --formula 2>/dev/null | wc -l | tr -d ' ')
    brew_c=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')
    plan+=("every Homebrew package ($brew_f formulae, $brew_c casks), then Homebrew itself")
  }
  plan+=("~/.local/share/mise and ~/.cache/mise (installed toolchains)")
  local rel
  while IFS= read -r rel; do plan+=("~/$rel"); done \
    < <(cd "$ROOT_DIR/dotfiles" 2>/dev/null && find . -type f ! -name '.DS_Store' | sed 's|^\./||')
  plan+=("~/.cursor ($(ls -1 "$HOME/.cursor/extensions" 2>/dev/null | wc -l | tr -d ' ') Cursor extensions)")
  plan+=("~/Library/Application Support/Cursor and Sublime Text")
  plan+=("~/Library/Colors")
  plan+=("~/Library/Application Support/sys (the desktop colour image)")
  plan+=("preferences for Cursor, Sublime Text and Ghostty")
  plan+=("the Dock and Finder settings, back to macOS defaults")
  plan+=("$ROOT_DIR/.state and $ROOT_DIR/.drift")

  doing "This will remove:"
  printf "    ${GREY}%s${RESET}\n" "${plan[@]}"
  echo
  note "It will NOT erase macOS, your user account, SSH or Screen Sharing."
  echo

  if [[ "$dry" == "1" ]]; then
    warn "Dry run — nothing removed. Run {{sys remove}} to do it."
    return 0
  fi

  confirm "Remove all of the above?" || { note "Nothing removed."; return 0; }
  echo

  if has_cmd brew; then
    # Some casks need sudo. Ask once here so the prompt has context, rather
    # than appearing unexplained in the middle of Homebrew's output.
    note "Some apps need your password to uninstall."
    sudo -v || warn "No sudo — some casks may fail to uninstall"
    doing "Uninstalling casks and formulae"
    brew list --cask 2>/dev/null | xargs -r brew uninstall --cask --force >/dev/null 2>&1
    brew list --formula 2>/dev/null | xargs -r brew uninstall --formula --force --ignore-dependencies >/dev/null 2>&1
    doing "Uninstalling Homebrew"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -- --force >/dev/null 2>&1
  fi

  doing "Removing installed files"
  rm -rf "$HOME/.local/share/mise" "$HOME/.cache/mise" \
         "$ROOT_DIR/.state" "$ROOT_DIR/.drift" 2>/dev/null

  # Editors, completely — extensions live in ~/.cursor, not Application Support.
  wipe "$HOME/.cursor"
  wipe "$HOME/Library/Application Support/Cursor"
  wipe "$HOME/Library/Application Support/Sublime Text"
  wipe "$HOME/Library/Colors"
  wipe "$HOME/Library/Application Support/sys"
  wipe "$HOME/Library/Application Support/system-config"
  wipe "$HOME/Library/Caches/Cursor"
  rm -f "$HOME/Library/Preferences/com.todesktop.230313mzl4w4u92.plist" \
        "$HOME/Library/Preferences/com.sublimetext.4.plist" \
        "$HOME/Library/Preferences/com.mitchellh.ghostty.plist" 2>/dev/null

  # Anything else the sync targets put on this machine.
  local repo_rel system_dir repo_dir rel
  while IFS='|' read -r repo_rel system_dir; do
    repo_dir="$ROOT_DIR/$repo_rel"
    [[ -d "$repo_dir" ]] || continue
    while IFS= read -r rel; do rm -f "$system_dir/$rel" 2>/dev/null; done < <(_tracked "$repo_dir")
  done < <(sync_targets)

  doing "Resetting the Dock and Finder"
  defaults delete com.apple.dock    >/dev/null 2>&1 || true
  defaults delete com.apple.finder  >/dev/null 2>&1 || true
  killall Dock Finder >/dev/null 2>&1 || true

  echo
  ok "Removed. The repo is still at $ROOT_DIR"
  warn "Open a new terminal now. This one still has the old shell hooks"
  warn "loaded, so it will complain that mise has gone — that is expected."
  print_fresh_user_steps
}

print_fresh_user_steps() {
  printf '\n%sTo install again from scratch:%s\n\n' "$GREY" "$RESET"
  printf '  %scurl -fsSL https://raw.githubusercontent.com/dwkns/sys/master/install.sh | bash%s\n\n' \
    "$WHITE" "$RESET"
}

# MailExporter ships as a signed .app on GitHub Releases, so setup downloads
# and verifies it rather than building from source: seconds instead of minutes,
# and no dependency on python3, the Xcode tools or a build succeeding. If no
# release matches this Mac's architecture, it falls back to building.
MAIL_EXPORTER_REPO="${MAIL_EXPORTER_REPO:-dwkns/mail-exporter}"
MAIL_EXPORTER_DIR="${MAIL_EXPORTER_DIR:-$HOME/Developer/mail-exporter}"

# True when version $1 is at least $2, comparing each dot-separated number
# (so 1.10 is newer than 1.9). Suffixes such as -beta are ignored. Bash only.
version_ge() {
  local -a a b
  local i x y
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 0
}

install_mail_exporter() {
  local stamp="$ROOT_DIR/.state/mailexporter"
  local arch; arch="$(uname -m)"
  local api="https://api.github.com/repos/$MAIL_EXPORTER_REPO/releases/latest"
  local json tag url

  json="$(curl -fsSL "$api" 2>/dev/null)" || json=""
  if [[ -n "$json" ]]; then
    read -r tag url <<<"$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
arch = sys.argv[1]
hit = next((a["browser_download_url"] for a in d.get("assets", [])
            if a["name"].endswith(".zip") and arch in a["name"]), "")
print(d.get("tag_name", ""), hit)' "$arch" 2>/dev/null)"
  fi

  if [[ -z "${url:-}" ]]; then
    note "No release for $arch — building from source instead"
    build_mail_exporter
    return
  fi

  if [[ -d /Applications/MailExporter.app && "$(cat "$stamp" 2>/dev/null)" == "$tag" ]]; then
    note "MailExporter $tag: already installed"
    return 0
  fi

  # Already this version, just never recorded? Then there is nothing to replace,
  # and leaving the bundle alone avoids needing permission to touch it at all.
  # Same version or newer (a local build ahead of the latest release)? Then
  # leave it: replacing would be pointless, or a downgrade.
  local have
  have="$(defaults read /Applications/MailExporter.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || true)"
  if [[ -n "$have" ]] && version_ge "${have#v}" "${tag#v}"; then
    if [[ "${have#v}" == "${tag#v}" ]]; then
      note "MailExporter $tag: already installed"
    else
      note "MailExporter $have is installed, newer than the latest release ($tag) — leaving it"
    fi
    [[ "${DRY_RUN:-0}" != "1" ]] && mkdir -p "$(dirname "$stamp")" && printf '%s\n' "$tag" > "$stamp"
    return 0
  fi

  # A dry run downloads nothing, so it must stop before the checksum check —
  # otherwise it verifies a file that was never fetched and reports a mismatch.
  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: download and verify MailExporter $tag"; return 0; }

  doing "Downloading MailExporter $tag"
  local tmp; tmp="$(mktemp -d)"
  if ! run curl -fsSL -o "$tmp/app.zip" "$url"; then
    warn "Download failed"; rm -rf "$tmp"; return 1
  fi

  # Verify against the published checksum when there is one — this is a 26MB
  # binary going into /Applications.
  local sha_url="$url.sha256" expected actual
  if expected="$(curl -fsSL "$sha_url" 2>/dev/null | awk '{print $1}')" && [[ -n "$expected" ]]; then
    actual="$(shasum -a 256 "$tmp/app.zip" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
      error "Checksum mismatch — refusing to install"
      rm -rf "$tmp"; return 1
    fi
    note "Checksum verified"
  else
    warn "No published checksum for this release"
  fi


  ditto -xk "$tmp/app.zip" "$tmp/x" 2>/dev/null || unzip -q "$tmp/app.zip" -d "$tmp/x"
  if [[ ! -d "$tmp/x/MailExporter.app" ]]; then
    error "Archive did not contain MailExporter.app"; rm -rf "$tmp"; return 1
  fi
  # Replace the app as this user. If that is refused — an app owned by another
  # account or by root — use the password already held for the run.
  if ! { rm -rf /Applications/MailExporter.app 2>/dev/null &&
         ditto "$tmp/x/MailExporter.app" /Applications/MailExporter.app 2>/dev/null; }; then
    note "Replacing MailExporter needs administrator rights"
    if ! { sudo_run rm -rf /Applications/MailExporter.app &&
           sudo_run ditto "$tmp/x/MailExporter.app" /Applications/MailExporter.app &&
           sudo_run chown -R "$(id -un)":admin /Applications/MailExporter.app; }; then
      error "Could not replace /Applications/MailExporter.app"
      note "macOS may be protecting it: System Settings ▸ Privacy & Security ▸ App Management ▸ allow your terminal app"
      rm -rf "$tmp"; return 1
    fi
  fi
  rm -rf "$tmp"

  mkdir -p "$(dirname "$stamp")" && printf '%s\n' "$tag" > "$stamp"
  ok "MailExporter $tag installed"
}

# Fallback: clone and build. Needs python3, the Xcode tools and a few minutes.
build_mail_exporter() {
  has_cmd git || { warn "git missing; skipping MailExporter"; return 1; }
  if [[ -d "$MAIL_EXPORTER_DIR/.git" ]]; then
    run git -C "$MAIL_EXPORTER_DIR" pull --ff-only >/dev/null 2>&1 || true
  else
    doing "Cloning $MAIL_EXPORTER_REPO"
    run mkdir -p "$(dirname "$MAIL_EXPORTER_DIR")"
    run git clone --quiet "https://github.com/$MAIL_EXPORTER_REPO.git" "$MAIL_EXPORTER_DIR" || {
      warn "Could not clone $MAIL_EXPORTER_REPO"; return 1; }
  fi
  local build="$MAIL_EXPORTER_DIR/apps/MailExporter/build.sh"
  [[ -x "$build" ]] || { warn "No build.sh in $MAIL_EXPORTER_DIR"; return 1; }
  doing "Building MailExporter — a few minutes, no output while it works"
  run bash "$build" >/dev/null 2>&1 || { warn "MailExporter build failed"; return 1; }
  [[ -d /Applications/MailExporter.app ]] || { warn "Build produced no installed app"; return 1; }
  ok "MailExporter built and installed"
}

# Paywall Down has no release other Macs can install. A Developer-signed .app
# built on one machine is tied to that machine's signature, so setup clones
# the private repo and builds the macOS scheme here. Xcode 27 rejects the
# project's macOS deployment target of 10.14, so the build passes 12.0 on the
# command line and leaves the repo alone. Signing stays on the project
# settings (Automatic, team LD2427W529).
PAYWALL_DOWN_REPO="${PAYWALL_DOWN_REPO:-dwkns/paywall-down}"
PAYWALL_DOWN_DIR="${PAYWALL_DOWN_DIR:-$HOME/Developer/paywall-down}"
PAYWALL_DOWN_APP="/Applications/Paywall Down.app"

install_paywall_down() {
  local quiet="${1:-}"
  local stamp="$ROOT_DIR/.state/paywall-down"

  has_cmd git || { warn "git missing; skipping Paywall Down"; return 1; }
  if [[ ! -d /Applications/Xcode.app ]]; then
    warn "Paywall Down needs Xcode — install it, then run {{sys setup}} again"
    return 1
  fi

  if [[ -d "$PAYWALL_DOWN_DIR/.git" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      note "dry run: update $PAYWALL_DOWN_DIR and rebuild Paywall Down if it changed"
      return 0
    fi
    paywall_down_update "$quiet"
  elif [[ -e "$PAYWALL_DOWN_DIR" ]]; then
    warn "$PAYWALL_DOWN_DIR exists but is not a git checkout — not touching it"
    return 1
  else
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      note "dry run: clone $PAYWALL_DOWN_REPO and build Paywall Down"
      return 0
    fi
    doing "Cloning $PAYWALL_DOWN_REPO"
    run mkdir -p "$(dirname "$PAYWALL_DOWN_DIR")"
    if ! paywall_down_clone; then
      warn "Could not clone $PAYWALL_DOWN_REPO"
      note "The repo is private. Sign in with {{gh auth login}}, then run {{sys setup}} again."
      return 1
    fi
  fi

  local rev
  rev="$(git -C "$PAYWALL_DOWN_DIR" rev-parse HEAD 2>/dev/null)" || {
    warn "Could not read $PAYWALL_DOWN_DIR"; return 1; }

  if [[ "${FORCE:-0}" != "1" && -d "$PAYWALL_DOWN_APP" && "$(cat "$stamp" 2>/dev/null)" == "$rev" ]]; then
    [[ "$quiet" == "quiet" ]] || note "Paywall Down ${rev:0:7}: already installed"
    return 0
  fi

  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: build and install Paywall Down"; return 0; }

  doing "Building Paywall Down — a few minutes, no output while it works"
  local dd log built
  dd="$(mktemp -d /tmp/paywall-down-build.XXXXXX)"
  log="$dd/build.log"
  # Scheme "pwd (macOS)" builds the app and its extension only, not iOS.
  # No code-sign overrides: Automatic signing and the project team are used.
  if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild \
        -project "$PAYWALL_DOWN_DIR/paywall-down.xcodeproj" \
        -scheme "pwd (macOS)" \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$dd" \
        MACOSX_DEPLOYMENT_TARGET=12.0 \
        build >"$log" 2>&1; then
    warn "Paywall Down build failed"
    note "Xcode has to be signed in to an Apple ID that can use team LD2427W529"
    tail -n 40 "$log" >&2 || true
    rm -rf "$dd"
    return 1
  fi

  built="$dd/Build/Products/Debug/Paywall Down.app"
  if [[ ! -d "$built" ]]; then
    warn "Build produced no Paywall Down.app"
    rm -rf "$dd"
    return 1
  fi
  if [[ ! -d "$built/Contents/PlugIns/pwd Extension.appex" ]]; then
    warn "Build produced no Safari extension"
    rm -rf "$dd"
    return 1
  fi

  # Same replace as MailExporter: this user first, then the password already
  # held for the run if /Applications will not take the copy.
  if ! { rm -rf "$PAYWALL_DOWN_APP" 2>/dev/null &&
         ditto "$built" "$PAYWALL_DOWN_APP" 2>/dev/null; }; then
    note "Replacing Paywall Down needs administrator rights"
    if ! { sudo_run rm -rf "$PAYWALL_DOWN_APP" &&
           sudo_run ditto "$built" "$PAYWALL_DOWN_APP" &&
           sudo_run chown -R "$(id -un)":admin "$PAYWALL_DOWN_APP"; }; then
      error "Could not replace $PAYWALL_DOWN_APP"
      note "macOS may be protecting it: System Settings ▸ Privacy & Security ▸ App Management ▸ allow your terminal app"
      rm -rf "$dd"
      return 1
    fi
  fi
  rm -rf "$dd"

  if ! codesign --verify --deep --strict "$PAYWALL_DOWN_APP" >/dev/null 2>&1; then
    warn "Installed Paywall Down did not pass codesign --verify"
    return 1
  fi

  # A copy that is already running (often from ~/Applications) keeps that
  # path. Quit it, then open this one so Safari registers the extension.
  osascript -e 'tell application id "com.dwkns.paywall-down" to quit' >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "Paywall Down" >/dev/null || break
    sleep 0.3
  done
  if ! open "$PAYWALL_DOWN_APP"; then
    warn "Could not launch Paywall Down — open it once so Safari registers the extension"
    return 1
  fi

  mkdir -p "$(dirname "$stamp")" && printf '%s\n' "$rev" > "$stamp"
  ok "Paywall Down ${rev:0:7} installed"
  note "If its Safari button does nothing: Settings ▸ Developer ▸ Allow unsigned extensions (one time, by hand)"
  return 0
}

# Fast-forward a clean checkout. Local edits and a detached HEAD are left
# alone — this directory is a working copy, not a throwaway build tree.
paywall_down_update() {
  local quiet="${1:-}" branch
  branch="$(git -C "$PAYWALL_DOWN_DIR" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    [[ "$quiet" == "quiet" ]] || warn "Paywall Down checkout is not on a branch — not pulling"
    return 0
  fi
  if [[ -n "$(git -C "$PAYWALL_DOWN_DIR" status --porcelain --untracked-files=no)" ]]; then
    [[ "$quiet" == "quiet" ]] || note "Paywall Down checkout has local changes — not pulling"
    return 0
  fi
  # GIT_TERMINAL_PROMPT=0: a missing login must fail the pull, not sit at
  # "Username:". Quiet sync hides git's own fatal line; setup still shows it.
  if [[ "$quiet" == "quiet" ]]; then
    GIT_TERMINAL_PROMPT=0 git -C "$PAYWALL_DOWN_DIR" pull --ff-only --quiet >/dev/null 2>&1 || true
  else
    GIT_TERMINAL_PROMPT=0 git -C "$PAYWALL_DOWN_DIR" pull --ff-only --quiet || \
      warn "Could not fast-forward $PAYWALL_DOWN_DIR"
  fi
  return 0
}

paywall_down_clone() {
  if has_cmd gh && gh auth status >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 gh repo clone "$PAYWALL_DOWN_REPO" "$PAYWALL_DOWN_DIR" -- --quiet
  else
    GIT_TERMINAL_PROMPT=0 git clone --quiet "https://github.com/$PAYWALL_DOWN_REPO.git" "$PAYWALL_DOWN_DIR"
  fi
}

# Optional extras — never run by `sys setup`, only by `sys extras`.
install_extras() {
  local bf="$ROOT_DIR/Brewfile.optional"
  if [[ -r "$bf" ]]; then
    install_homebrew
    doing "Installing optional extras"
    run brew bundle --file "$bf"
  fi

  local file="$ROOT_DIR/config/mas-apps-optional.txt"
  [[ -r "$file" ]] || return 0
  has_cmd mas || return 0
  local installed
  installed="$(mas list 2>/dev/null)" || { warn "App Store unreachable; skipping optional apps"; return 0; }

  local line id
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    id="${line%%[^0-9]*}"
    [[ -n "$id" ]] || continue
    if printf '%s\n' "$installed" | awk -v id="$id" '$1==id{f=1} END{exit !f}'; then
      note "already installed: $(printf '%s' "$line" | sed 's/^[0-9]*[[:space:]]*#*[[:space:]]*//')"
    else
      run mas install "$id"
    fi
  done < "$file"
}

apply_macos_defaults() {
  run bash "$ROOT_DIR/macos.sh"
}

# Keyboard and trackpad from config/input. Runs on every sync as well as at
# setup, so it must stay quiet and quick: plain defaults writes, no restarts.
apply_input_settings() {
  local file="$ROOT_DIR/config/input"
  [[ -r "$file" ]] || return 0

  # Work out which settings differ from what is already set, reading each
  # preferences domain once rather than asking for every key separately.
  # Prints the config lines that need writing, with "trackpad" expanded into
  # the two real domains so each can be written on its own.
  local diffs
  if ! diffs="$(/usr/bin/python3 - "$file" 2>/dev/null <<'PY'
import plistlib, subprocess, sys

TRACKPADS = ["com.apple.AppleMultitouchTrackpad",
             "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
cache = {}

def domain(name):
    if name not in cache:
        host = name.startswith("currentHost:")
        real = name.split(":", 1)[1] if host else name
        cmd = ["defaults"] + (["-currentHost"] if host else []) + ["export", real, "-"]
        out = subprocess.run(cmd, capture_output=True).stdout
        try:
            cache[name] = plistlib.loads(out) if out else {}
        except Exception:
            cache[name] = {}
    return cache[name]

def same(have, kind, want):
    if have is None:
        return False
    try:
        if kind == "bool":
            return bool(have) == (want == "true")
        if kind == "int":
            return int(have) == int(want)
        if kind == "float":
            return abs(float(have) - float(want)) < 1e-9
        return str(have) == want
    except (TypeError, ValueError):
        return False

for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    dom, key, kind, want = line.split("|", 3)
    for real in (TRACKPADS if dom == "trackpad" else [dom]):
        if not same(domain(real).get(key), kind, want):
            print(real + "|" + key + "|" + kind + "|" + want)
PY
)"; then
    # No python to compare with: fall back to writing everything, quietly.
    diffs="$(grep -vE '^[[:space:]]*(#|$)' "$file" | awk -F'|' '
      $1 == "trackpad" { print "com.apple.AppleMultitouchTrackpad|" $2 "|" $3 "|" $4
                         print "com.apple.driver.AppleBluetoothMultitouch.trackpad|" $2 "|" $3 "|" $4; next }
      { print }')"
  fi

  local domain key type value n=0
  while IFS='|' read -r domain key type value; do
    [[ -z "$domain" ]] && continue
    if [[ "$domain" == currentHost:* ]]; then
      run defaults -currentHost write "${domain#currentHost:}" "$key" "-$type" "$value"
    else
      run defaults write "$domain" "$key" "-$type" "$value"
    fi
    n=$((n + 1))
  done <<<"$diffs"

  # Nothing differed: nothing to write, nothing to apply, nothing to say.
  (( n == 0 )) && return 0

  # These normally wait for the next login. activateSettings applies them
  # straight away. It is undocumented, so it is best effort only.
  local activate=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings
  if [[ "${DRY_RUN:-0}" != "1" && -x "$activate" ]]; then
    "$activate" -u >/dev/null 2>&1 || true
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    note "Keyboard and trackpad: $n setting(s) would change"
  else
    note "Keyboard and trackpad: $n setting(s) updated"
  fi
}

# Solid desktop colour from config/desktop-colour. Setup only, once per
# version of that file.
set_desktop_colour() {
  local setter="$ROOT_DIR/bin/set-desktop-colour"
  [[ -x "$setter" && -r "$ROOT_DIR/config/desktop-colour" ]] || return 1
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    ROOT_DIR="$ROOT_DIR" "$setter" --dry-run
  else
    ROOT_DIR="$ROOT_DIR" "$setter"
  fi
}

set_default_terminal() {
  has_cmd duti || { warn "duti not installed; skipping default terminal"; return 0; }
  [[ -d /Applications/Ghostty.app ]] || { warn "Ghostty not installed; skipping"; return 0; }

  doing "Making Ghostty the default terminal"
  local id="com.mitchellh.ghostty" ext
  run duti -s "$id" com.apple.terminal.shell-script all
  run duti -s "$id" public.unix-executable all
  for ext in command tool sh zsh; do
    run duti -s "$id" ".$ext" all 2>/dev/null || true
  done
}

set_machine_name() {
  local name="$1"
  [[ -n "$name" ]] || return 0

  # One name, used for all three, as the original did. Lowercased, spaces to
  # hyphens, other punctuation dropped — scutil rejects those in HostName and
  # LocalHostName, and keeping the three identical is the whole point.
  local clean
  clean="$(printf '%s' "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | tr -cd '[:alnum:]-' \
    | sed 's/^-*//;s/-*$//;s/--*/-/g')"
  [[ -n "$clean" ]] || { warn "Not a usable computer name: $name"; return 1; }

  doing "Setting computer name to $clean"
  run sudo_run scutil --set ComputerName  "$clean"
  run sudo_run scutil --set HostName      "$clean"
  run sudo_run scutil --set LocalHostName "$clean"
}


# The default computer name: dwkns-<type>-<chip>, e.g. dwkns-mbp-m1 or
# dwkns-mini-m4. The model name comes from system_profiler, not hw.model —
# newer Macs report generic identifiers like Mac14,3 that do not say "mini".
MACHINE_NAME_PREFIX="${MACHINE_NAME_PREFIX:-dwkns}"
default_machine_name() {
  local model chip type proc
  model="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}')"
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  case "$model" in
    "MacBook Pro"*) type=mbp ;;
    "MacBook Air"*) type=mba ;;
    "Mac mini"*)    type=mini ;;
    "Mac Studio"*)  type=studio ;;
    "Mac Pro"*)     type=macpro ;;
    iMac*)          type=imac ;;
    *)              type=mac ;;
  esac
  case "$chip" in
    "Apple M"*) proc="$(printf '%s' "$chip" | awk '{print tolower($2)}')" ;;  # "Apple M1 Max" -> m1
    *Intel*)    proc=intel ;;
    *)          proc="$(uname -m)" ;;
  esac
  printf '%s-%s-%s\n' "$MACHINE_NAME_PREFIX" "$type" "$proc"
}

# Asked once per machine during setup. 15 seconds, then the default.
prompt_machine_name() {
  local current reply default
  current="$(scutil --get ComputerName 2>/dev/null || echo "unknown")"
  default="${DEFAULT_MACHINE_NAME:-$(default_machine_name)}"

  doing "Computer name"
  note "Currently: $current"
  printf '    New name, or Return to accept "%s" (15s): ' "$default"

  reply=""
  if { true </dev/tty; } 2>/dev/null; then
    read -t 15 -r reply </dev/tty || true
  fi
  echo

  reply="$(printf '%s' "${reply:-$default}" | sed 's/^ *//;s/ *$//')"
  [[ -n "$reply" ]] || reply="$default"
  set_machine_name "$reply"
}


# Printed at the end of setup. Only lists things that are actually still
# outstanding, checked live — a list of things you have already done is noise.
print_manual_steps() {
  local -a todo=()


  [[ "${MAS_SKIPPED:-0}" == "1" ]] && \
    todo+=("🛒  App Store apps were skipped — sign in, then ${WHITE}sys setup${RESET} again")

  has_cmd cursor || \
    todo+=("🧩  Open Cursor once so its command appears, then ${WHITE}sys setup${RESET} for its extensions")

  ssh_has_key && ! ssh_shared && \
    todo+=("🔑  Share this machine's SSH key: ${WHITE}sys sync${RESET} — it signs you in to GitHub once, in the browser")

  [[ -d "/Applications/Paywall Down.app" ]] || \
    todo+=("🧭  Paywall Down was not installed — it needs Xcode, signed in to team LD2427W529, then ${WHITE}sys setup${RESET}")

  todo+=("🧭  Safari ▸ Settings ▸ Developer ▸ Allow unsigned extensions, if Paywall Down's button does nothing — by hand, once")
  todo+=("🔐  Sign in to 1Password, Slack, Notion and Figma")
  todo+=("🔓  Give Ghostty Full Disk Access — System Settings ▸ Privacy & Security")
  todo+=("🔄  Log out and back in — some macOS settings only apply at login")

  # No right-hand border: emoji are double-width and terminals disagree on
  # how much, so anything padded to a fixed column ends up ragged.
  header "🎉" "All set — a few things only you can do"
  printf "  ${GREY}%b${RESET}\n" "${todo[@]}"
  echo
  printf '  %sTip:%s %ssys doctor%s%s tells you if anything is still missing.%s\n\n' \
    "$GREY" "$RESET" "$WHITE" "$RESET" "$GREY" "$RESET"
}

