#!/usr/bin/env bash
# Colours, logging and small helpers. Sourced by every script and by .zshrc,
# so it must stay valid in both bash and zsh (no arrays, no `read -p`).

[[ -n "${_SYSCFG_COMMON:-}" ]] && return 0
_SYSCFG_COMMON=1

ROOT_DIR="${ROOT_DIR:-$HOME/.sys}"

# Four colours, one meaning each. Everything sys prints uses only these, so
# the colour tells you what kind of thing you are reading without reading it.
#
#   GREY    supporting copy: explanations, hints, what to do next
#   GREEN   good: done, working, reachable, installed
#   ORANGE  off, but expected: the consequence of a choice you made, and we
#           know it — a tailnet route while Tailscale is switched off. Not
#           working, not a fault.
#   RED     bad: failed, missing, unexplained — worth looking at
#   WHITE   the subject: titles, machine and file names, commands to type
# WHITE starts with 22 (normal intensity) because bold does NOT cancel dim:
# inside a grey sentence a plain \033[1m stays grey-and-bold, which is what
# made commands look half-lit. 97 is bright white, so it is white whatever
# the terminal's default foreground happens to be.
GREY=$'\033[2m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
ORANGE=$'\033[38;5;208m'; WHITE=$'\033[22;1;97m'; RESET=$'\033[0m'

# Older names, kept so nothing breaks, mapped onto the four above.
DIM="$GREY"; BOLD="$WHITE"; CYAN="$WHITE"; YELLOW="$RED"

# One glyph per kind of message, so output can be skimmed:
#   ▸ doing something   ✓ it worked   · detail   ▲ careful   ✗ broken
# Anything in {{double braces}} is a command the reader could type. It is
# shown in white wherever it appears, so no message colours one by hand.
# Braces rather than backticks: messages live in double quotes, where
# backticks would run the command instead of printing it.
# $2 is the colour the sentence returns to afterwards.
hl() {
  local ambient="${2:-$RESET}"
  printf '%s' "$1" | sed "s/{{\\([^}]*\\)}}/${WHITE}\\1${RESET}${ambient}/g"
}

doing() { printf '%s▸%s %s\n'   "$GREEN" "$RESET" "$(hl "$*")"; }
ok()    { printf '%s✓%s %s\n'   "$GREEN" "$RESET" "$(hl "$*")"; }
# A note is supporting copy, so the sentence itself is grey.
note()  { printf '%s  ·%s %s%s%s\n' "$GREY" "$RESET" "$GREY" "$(hl "$*" "$GREY")" "$RESET"; }
warn()  { printf '%s  ▲%s %s\n' "$RED" "$RESET" "$(hl "$*")" >&2; }
error() { printf '%s  ✗%s %s\n' "$RED" "$RESET" "$(hl "$*")" >&2; }
die()   { error "$*"; exit 1; }

# A titled rule, used at the top of anything worth reading properly.
#   header "🩺" "System check"
#   header "📦" "Installing apps" "[1/8]" "$WHITE"  rules in that colour
header() {
  local rule="────────────────────────────────────────────────────────"
  local colour="${4:-$GREY}" suffix=""
  [[ -n "${3:-}" ]] && suffix="  $GREY$3$RESET"
  printf '\n%s%s%s\n' "$colour" "$rule" "$RESET"
  printf ' %s  %s%s%s%s\n' "$1" "$WHITE" "$2" "$RESET" "$suffix"
  printf '%s%s%s\n\n' "$colour" "$rule" "$RESET"
}

# "4m 12s" from a number of seconds.
elapsed() {
  local s="$1"
  (( s < 60 )) && { printf '%ds' "$s"; return; }
  printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
}

has_cmd()   { command -v "$1" >/dev/null 2>&1; }
is_macos()  { [[ "$(uname -s)" == "Darwin" ]]; }
timestamp() { date "+%Y%m%d-%H%M%S"; }

# Run a command, or just print it when DRY_RUN=1.
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    note "dry run: $*"
  else
    "$@"
  fi
}

# Run a command with a time limit, stdin closed so it can't sit at a prompt.
# macOS has no timeout(1) and doctor must never block.
with_timeout() {
  local secs="$1"; shift
  "$@" </dev/null >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  return $rc
}

# Run a command with a time limit and its output intact (with_timeout throws
# the output away). macOS has no timeout(1), but has perl. Exit 142 means the
# limit was hit. For ssh, this is the only thing that bounds the LOGIN:
# ConnectTimeout stops at the TCP connect, so a stuck agent or a server that
# never answers authentication would otherwise wait for ever.
timed() {
  local secs="$1"; shift
  # perl forks the command and waits, so on the limit it is perl that exits
  # 142 — not the command dying of SIGALRM, which makes bash print
  # "Alarm clock" into the middle of sys's output.
  perl -e '
    my $s = shift; my $pid = fork; defined $pid or exit 126;
    if (!$pid) { exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 142 };
    alarm $s; waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);' "$secs" "$@"
}

# Ask a yes/no question that answers itself if left alone.
#   ask_timeout <seconds> <default: y|n> <question>
ask_timeout() {
  local secs="$1" default="$2" question="$3" reply="" hint
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  printf '%s %s — %ss, then %s: ' "$question" "$hint" "$secs" \
    "$([[ "$default" == y ]] && echo yes || echo no)"
  if { true </dev/tty; } 2>/dev/null; then
    read -t "$secs" -r reply </dev/tty || true
  fi
  echo
  [[ "${reply:-$default}" == [Yy]* ]]
}

# Ask before doing something. ASSUME_YES=1 skips the prompt.
#
# Reads from /dev/tty rather than stdin: under `curl ... | bash` stdin is the
# script itself, so a plain `read` gets EOF and the answer is always no.
confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  # Actually try to open it: the device node is readable by mode even when
  # there is no controlling terminal to attach to.
  if { true </dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "${1:-Are you sure?}" >/dev/tty
    read -r reply </dev/tty || return 1
  else
    # No terminal at all (CI, a cron job): refuse rather than guess.
    warn "No terminal for confirmation — re-run with --yes"
    return 1
  fi
  [[ "$reply" == [Yy]* ]]
}
