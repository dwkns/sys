#!/usr/bin/env bash
# Set up a new Mac with one command:
#
#   curl -fsSL https://raw.githubusercontent.com/dwkns/sys/master/install.sh | bash
#
# Runs start to finish. You will be asked for your password once, and to
# accept the Command Line Tools dialog if they are not installed yet.
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$HOME/.sys}"
REPO="https://github.com/dwkns/sys.git"

# The same colours as lib/common.sh, repeated because the repo is not cloned
# yet when this runs: grey for copy, white for a command you would type.
GREY=$'\033[2m'; WHITE=$'\033[22;1;97m'; GREEN=$'\033[0;32m'; RESET=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
copy() { printf '%s%s%s\n' "$GREY" "$*" "$RESET"; }

# Where to read answers from. NEVER redirect this script's own stdin: piped
# into bash, stdin IS the script, so `exec </dev/tty` makes bash try to read
# the rest of the script from the keyboard and hang forever. Redirect only
# the individual commands that prompt.
if { true </dev/tty; } 2>/dev/null; then TTY=/dev/tty; else TTY=/dev/null; fi

say "Setting up this Mac from $REPO"

# ── Xcode Command Line Tools ─────────────────────────────────────────────────
# git needs these. The installer is a GUI dialog, so wait for it rather than
# bailing out and making the user start again.
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools"
  copy "    A dialog will appear — click Install and accept the licence."
  xcode-select --install >/dev/null 2>&1 || true

  printf '    Waiting for it to finish'
  for _ in $(seq 1 240); do              # up to 40 minutes
    xcode-select -p >/dev/null 2>&1 && break
    printf '.'; sleep 10
  done
  echo

  if ! xcode-select -p >/dev/null 2>&1; then
    copy "Command Line Tools did not install. Run ${WHITE}xcode-select --install${RESET}${GREY},"
    copy "let it finish, then run this command again."
    exit 1
  fi
  say "Command Line Tools installed"
fi

# git can exist but refuse to run until the licence is agreed.
if ! git --version >/dev/null 2>&1; then
  copy "git is not working yet. Open Terminal, run ${WHITE}git --version${RESET}${GREY}, accept any"
  copy "prompt, then run this command again."
  exit 1
fi

# ── Password ─────────────────────────────────────────────────────────────────
# Not asked here: sys setup asks once and holds it for the whole run. Asking
# here as well would only mean typing it twice.

# ── The repo ─────────────────────────────────────────────────────────────────
# Only cloned when missing: sys setup itself pulls the latest and restarts
# if that changed sys, so pulling here too would only do the work twice.
if [[ ! -d "$ROOT_DIR/.git" ]]; then
  say "Cloning into $ROOT_DIR"
  if ! git clone --quiet "$REPO" "$ROOT_DIR"; then
    copy "Could not clone $REPO — check your network and try again."
    exit 1
  fi
fi

# Running this installer IS the confirmation, so do not ask again.
export SYS_FROM_INSTALLER=1
exec "$ROOT_DIR/bin/sys" setup --yes "$@" <"$TTY"
