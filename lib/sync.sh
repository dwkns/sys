#!/usr/bin/env bash
# Mirrors config between this repo and the system.
#
# Each tracked area is just "a repo directory that maps onto a system
# directory". The contents of the repo directory ARE the manifest, so there
# is no separate list to keep in step.
#
#   sync_install   repo -> system
#   sync_backup    system -> repo   (only files the repo already tracks)

source "${ROOT_DIR:-$HOME/.sys}/lib/common.sh"

SUBLIME_USER_DIR="$HOME/Library/Application Support/Sublime Text/User"

# repo dir | system dir
sync_targets() {
  cat <<TARGETS
dotfiles|$HOME
colors|$HOME/Library/Colors
config/sublime-config|$SUBLIME_USER_DIR
config/cursor|$HOME/Library/Application Support/Cursor/User
TARGETS
}

# Files tracked in a repo dir, as paths relative to it.
_tracked() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f ! -name '.DS_Store' ! -name '*.sublime_license' -print0 |
    while IFS= read -r -d '' f; do printf '%s\n' "${f#"$dir"/}"; done
}

# Copy repo -> system. The repo always wins — that is what syncing means — but
# any system file that would be overwritten with different content is stashed
# in .drift/ first, so a local edit is never silently lost.
# Sets SYNC_CHANGED to the number of files it actually replaced.
sync_install() {
  local drift="$ROOT_DIR/.drift"
  SYNC_CHANGED=0
  local repo_rel system_dir repo_dir rel src dst drifted=0

  while IFS='|' read -r repo_rel system_dir; do
    repo_dir="$ROOT_DIR/$repo_rel"
    [[ -d "$repo_dir" ]] || continue

    while IFS= read -r rel; do
      src="$repo_dir/$rel"; dst="$system_dir/$rel"

      # Already identical: nothing to do, unless forced.
      local same=0
      [[ -e "$dst" ]] && cmp -s "$src" "$dst" && same=1
      [[ "$same" == "1" && "${FORCE:-0}" != "1" ]] && continue

      # Only stash a file that actually differs — forcing should not fill
      # .drift with copies of files that were already correct.
      if [[ -e "$dst" && "$same" == "0" ]]; then
        run mkdir -p "$drift/$repo_rel/$(dirname "$rel")"
        run cp -a "$dst" "$drift/$repo_rel/$rel"
        drifted=1
      fi

      run mkdir -p "$(dirname "$dst")"
      run cp -a "$src" "$dst"
      SYNC_CHANGED=$((SYNC_CHANGED + 1))
    done < <(_tracked "$repo_dir")
  done < <(sync_targets)

  if [[ "$drifted" == "1" ]]; then
    note "Replaced files that differed. The old copies are in .drift/"
    note "Keep them instead?  {{cp -a .drift/<path> <destination>}}, or {{sys push}} next time."
  fi
  return 0
}

# Sign in to GitHub with the same "device flow" gh uses, but driven from here
# so gh never draws an interactive prompt: those query the terminal and the
# replies land on screen as escape codes. Prints a code, opens the browser,
# waits for approval, hands the token to gh. Nothing else touches the terminal.
github_device_login() {
  local client="178c6fc778ccc68e1d6a"   # gh's own OAuth app, so gh owns the token
  local resp device code uri interval token err waited=0
  resp="$(curl -fsS -X POST https://github.com/login/device/code \
            -d "client_id=$client" -d "scope=public_repo" 2>/dev/null)" || {
    warn "Could not reach GitHub to start the sign-in"; return 1; }
  field() { printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | sed 's/%3A/:/g;s/%2F/\//g'; }
  device="$(field "$resp" device_code)"; code="$(field "$resp" user_code)"
  uri="$(field "$resp" verification_uri)"; interval="$(field "$resp" interval)"
  [[ -n "$device" && -n "$code" ]] || { warn "GitHub gave no sign-in code"; return 1; }

  printf '\n    Your code:  %s%s%s\n    Type it on the GitHub page that is opening: %s\n\n' "$BOLD" "$code" "$RESET" "$uri"
  { open "$uri" 2>/dev/null || xdg-open "$uri" 2>/dev/null; } >/dev/null 2>&1 &
  note "Waiting for you to approve it there…"

  local failures=0
  while (( waited < 900 )); do
    sleep "${interval:-5}"; waited=$((waited + ${interval:-5}))
    if ! resp="$(curl -fsS -X POST https://github.com/login/oauth/access_token \
              -d "client_id=$client" -d "device_code=$device" \
              -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null)"; then
      failures=$((failures + 1)); (( failures >= 6 )) && { warn "Lost contact with GitHub"; return 1; }
      continue
    fi
    token="$(field "$resp" access_token)"
    [[ -n "$token" ]] && break
    err="$(field "$resp" error)"
    case "$err" in
      authorization_pending) ;;
      slow_down) sleep 5 ;;
      expired_token) warn "That code expired"; return 1 ;;
      access_denied) warn "You cancelled the sign-in"; return 1 ;;
      *) warn "GitHub said: ${err:-nothing useful}"; return 1 ;;
    esac
  done
  [[ -n "$token" ]] || { warn "Timed out waiting for the sign-in"; return 1; }
  printf '%s\n' "$token" | gh auth login --hostname github.com --with-token >/dev/null 2>&1 \
    || { warn "gh did not accept the sign-in"; return 1; }
  ok "Signed in to GitHub"
}

# If a pull changed sys itself, this running copy is stale — bash parsed it
# before the new version arrived. Start again with the new one. SYS_RESTARTED
# stops it looping if something goes wrong. Used by setup and sync.
restart_if_updated() {
  local before="$1" after="$2"
  [[ "$before" != "$after" && "${SYS_RESTARTED:-0}" != "1" ]] || return 0
  git -C "$ROOT_DIR" diff --quiet "$before" "$after" -- bin lib 2>/dev/null && return 0
  doing "sys was updated — restarting with the new version"
  export SYS_RESTARTED=1
  exec "$ROOT_DIR/bin/sys" ${SYS_ARGV[@]+"${SYS_ARGV[@]}"}
}

# The repo was ~/.system-config, cloned from dwkns/system-install; both are now
# "sys". Run by sync and setup straight after the pull, so one `sys sync all`
# moves every machine. Moves the folder (.state and .drift go with it), leaves
# ~/.system-config as a link so old shells, PATHs and remote callers still
# work, then restarts from the new place. Delete the link by hand once nothing
# uses it. Safe to run every time: it does nothing once done.
SYS_HOME="$HOME/.sys"
SYS_OLD_HOME="$HOME/.system-config"
SYS_REPO_URL="https://github.com/dwkns/sys.git"
migrate_root() {
  local url
  url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *dwkns/system-install*) run git -C "$ROOT_DIR" remote set-url origin "$SYS_REPO_URL" ;;
  esac

  # Linux: `sys` on PATH is a link that ssh-access made into the old folder.
  local bin="$HOME/.local/bin/sys"
  if [[ -L "$bin" && "$(readlink "$bin")" == "$SYS_OLD_HOME/"* ]]; then
    run ln -sfn "$SYS_HOME/bin/sys" "$bin"
  fi

  [[ "$ROOT_DIR" == "$SYS_OLD_HOME" && ! -L "$SYS_OLD_HOME" ]] || return 0
  if [[ -e "$SYS_HOME" ]]; then
    warn "Both {{$SYS_OLD_HOME}} and {{$SYS_HOME}} exist — not moving anything"
    note "Keep one: the repo belongs in {{$SYS_HOME}}"
    return 0
  fi
  doing "Moving the repo to $SYS_HOME"
  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: {{mv $SYS_OLD_HOME $SYS_HOME}}, then link the old name to it"; return 0; }
  mv "$SYS_OLD_HOME" "$SYS_HOME" || die "Could not move $SYS_OLD_HOME to $SYS_HOME"
  ln -s .sys "$SYS_OLD_HOME" || warn "Moved, but could not leave a link at $SYS_OLD_HOME"
  [[ -L "$bin" ]] && ln -sfn "$SYS_HOME/bin/sys" "$bin"
  ok "The repo is now $SYS_HOME"
  export SYS_RESTARTED=1
  exec "$SYS_HOME/bin/sys" ${SYS_ARGV[@]+"${SYS_ARGV[@]}"}
}

# Fast-forward to the latest repo (local edits set aside and put back), then
# restart if that changed sys. Never fatal: a machine that cannot reach
# GitHub carries on with the copy on disk.
update_self() {
  git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local before after
  doing "Updating $ROOT_DIR"
  before="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo none)"
  run git -C "$ROOT_DIR" pull --ff-only --autostash --quiet 2>/dev/null \
    || note "Could not update; continuing with the copy on disk"
  after="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo none)"
  restart_if_updated "$before" "$after"
}

# What is about to be installed: the Brewfile lines added since the last
# install here, so a change is never applied unseen.
show_brewfile_changes() {
  local last="$ROOT_DIR/.state/Brewfile.last"
  if [[ ! -f "$last" ]]; then note "First install of this Brewfile here"; return 0; fi
  diff "$last" "$ROOT_DIR/Brewfile" 2>/dev/null | grep -E '^[<>]' | sed 's/^</    removed: /;s/^>/    added:   /' | head -20 || true
  return 0
}

# Push commits that already exist. Never stops at a bare "Username:" prompt: a
# machine with no GitHub login saved is signed in, once.
push_repo() {
  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: {{git push}}"; return 0; }
  local err
  if err="$(env GIT_TERMINAL_PROMPT=0 git -C "$ROOT_DIR" push --quiet 2>&1)"; then return 0; fi

  # Only a missing login gets the sign-in. Anything else (someone else pushed
  # first, no network) is reported as what it is and retried next sync.
  if ! printf '%s' "$err" | grep -qiE 'could not read Username|Authentication failed|terminal prompts disabled|Permission to .* denied'; then
    warn "Could not push to GitHub — $(printf '%s' "$err" | grep -v '^$' | tail -1)"
    note "Will try again on the next {{sys sync}}"
    return 1
  fi

  # No login saved: sign in right here — a code and a browser page — then
  # let gh hand git its credentials from now on.
  if has_cmd gh && { true </dev/tty; } 2>/dev/null; then
    doing "This machine needs a GitHub login to push — signing in once with gh"
    if ! gh auth status -h github.com >/dev/null 2>&1; then
      github_device_login || { warn "GitHub sign-in did not finish — run {{sys sync}} again to retry"; return 1; }
    fi
    gh auth setup-git -h github.com >/dev/null 2>&1 || true
    if env GIT_TERMINAL_PROMPT=0 git -C "$ROOT_DIR" push --quiet 2>/dev/null; then
      ok "Signed in to GitHub — pushed. You will not be asked again on this machine"
      return 0
    fi
  fi
  warn "Could not push to GitHub — this machine has no GitHub login saved"
  note "Once, on this machine: {{gh auth login}} then {{gh auth setup-git}} — then {{sys sync}} again"
  return 1
}

# Copy system -> repo, for files the repo already tracks.
sync_backup() {
  local repo_rel system_dir repo_dir rel src dst
  while IFS='|' read -r repo_rel system_dir; do
    repo_dir="$ROOT_DIR/$repo_rel"
    [[ -d "$repo_dir" && -d "$system_dir" ]] || continue

    while IFS= read -r rel; do
      src="$system_dir/$rel"; dst="$repo_dir/$rel"
      [[ -e "$src" ]] || { warn "missing on system: $src"; continue; }
      run mkdir -p "$(dirname "$dst")"
      run cp -a "$src" "$dst"
    done < <(_tracked "$repo_dir")
  done < <(sync_targets)
}
