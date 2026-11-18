#!/usr/bin/env bash
# sys tmux — the two things about tmux worth a shortcut, and a reminder of
# the rest.
#
#   sys tmux        a short guide
#   sys tmux list   the sessions on this machine
#   sys tmux NAME   go into the session called NAME
#   sys tmux claude start the Claude Code sessions that should always be running
#
# Nothing here changes what `tmux` itself does. NAME must already exist: a
# mistyped name is an error, not a new session left running.

source "${ROOT_DIR:-$HOME/.sys}/lib/common.sh"

# Over a non-interactive ssh command PATH is bare, so look where Homebrew puts it.
_tmux_need() {
  has_cmd tmux || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  has_cmd tmux || die "tmux is not installed"
}

tmux_list() {
  _tmux_need
  local rows name windows attached running dir state
  rows="$(tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null)"
  header "🧵" "tmux sessions"
  if [[ -z "$rows" ]]; then
    note "None running here — {{tmux new -s NAME}} starts one"
    echo
    return 0
  fi
  while IFS='|' read -r name windows attached running dir; do
    running="${running%.exe}"                 # claude shows as claude.exe
    dir="${dir/#$HOME/~}"
    state=""
    [[ "$attached" != "0" ]] && state="  ${GREEN}in use${RESET}"
    printf '    %ssys tmux %-12s%s %s%-8s %s%s%s\n' \
      "$WHITE" "$name" "$RESET" "$GREY" "$running" "$dir" "$RESET" "$state"
  done <<<"$rows"
  echo
}

tmux_attach() {
  local name="$1"
  _tmux_need
  case "$name" in
    *[!A-Za-z0-9_-]*) die "A tmux session name is letters, digits, - and _ only" ;;
  esac
  # "=" makes the match exact: without it tmux takes "fr" to mean "frame".
  tmux has-session -t "=$name" 2>/dev/null \
    || die "No tmux session called $name here — {{sys tmux list}} shows them, {{tmux new -s $name}} starts it"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: go into the tmux session $name"; return 0; fi
  # Already inside tmux: switch this client over. Attaching would nest one
  # tmux in another, which tmux refuses.
  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "=$name"
  fi
  exec tmux attach-session -t "=$name"
}

# `sys tmux claude`: start the Claude Code sessions in config/claude-sessions,
# on whichever machine the list names — here, by running bin/claude-sessions,
# and on any other machine over ssh, so it works from a laptop when the
# sessions live on the mini. Sessions already running are left alone, so it is
# safe at any time. The login LaunchAgent does the same thing after a restart;
# this is for when you want them back without one.
tmux_claude() {
  local list="$ROOT_DIR/config/claude-sessions" me machines m a rc=0 extra=""
  # `sys tmux claude fresh [NAME]`: a new Remote Control identity for running
  # sessions instead of starting missing ones. See bin/claude-sessions.
  if [[ "${1:-}" == "fresh" ]]; then
    case "${2:-}" in *[!A-Za-z0-9_-]*) die "A tmux session name is letters, digits, - and _ only" ;; esac
    extra="--fresh ${2:-}"
  elif [[ -n "${1:-}" ]]; then
    die "Unknown: sys tmux claude $1 — {{sys tmux claude}} or {{sys tmux claude fresh [NAME]}}"
  fi
  [[ -r "$list" ]] || die "No config/claude-sessions in the repo"
  me="$(ssh_machine)"
  machines="$(sed 's/#.*//' "$list" | awk -F'|' 'NF >= 3 { gsub(/[ \t]/, "", $1); if ($1 != "" && !seen[$1]++) print $1 }')"
  [[ -n "$machines" ]] || { note "config/claude-sessions lists no sessions"; return 0; }

  for m in $machines; do
    if [[ "$m" == "$me" ]]; then
      "$ROOT_DIR/bin/claude-sessions" $extra || rc=1  # DRY_RUN reaches it through the environment
      continue
    fi
    a="$(ssh_alias "$m")"
    header "🧵" "Claude sessions on $a" "" "$WHITE"
    if ! "$ROOT_DIR/bin/ssh-reach" "$m" && ! "$ROOT_DIR/bin/ssh-reach" "$m.local"; then
      warn "$a is not reachable right now"; rc=1; continue
    fi
    # A login that never completes must not hang silently (see `timed`).
    if ! timed 15 ssh -o BatchMode=yes "$a" true 2>/dev/null; then
      warn "$a: could not log in — is this machine let in there?"; rc=1; continue
    fi
    # -t so the output there is drawn as it would be at its own prompt.
    if ssh -t -o BatchMode=yes -o ConnectTimeout=8 "$a" \
         "test -x ~/.sys/bin/claude-sessions || { echo 'claude-sessions is not installed here: run sys sync on it'; exit 99; }; DRY_RUN=${DRY_RUN:-0} exec ~/.sys/bin/claude-sessions $extra"; then
      :
    else
      [[ $? == 99 ]] || warn "$a: some sessions did not start (see above)"
      rc=1
    fi
  done
  return $rc
}

tmux_guide() {
  local c="$WHITE" g="$GREY" x="$RESET" cmd text
  printf '%stmux%s %s— a session keeps running on the machine when you disconnect%s\n\n' "$WHITE" "$RESET" "$GREY" "$RESET"
  # '^' separates the two columns: one of the keys is a literal '|'.
  while IFS='^' read -r cmd text; do
    [[ -z "$cmd$text" ]] && { echo; continue; }
    if [[ -z "$text" ]]; then printf '%s%s%s\n' "$g" "$cmd" "$x"
    else printf '  %s%-22s%s%s%s%s\n' "$c" "$cmd" "$x" "$g" "$(hl "$text" "$g")" "$x"
    fi
  done <<'GUIDE'
sys tmux list^The sessions on this machine
sys tmux NAME^Go into the session called NAME
sys tmux claude^Start the Claude sessions that should always be running
sys tmux claude fresh^Give them a new Remote Control identity ({{fresh NAME}} for one)
tmux new -s NAME^Start a new session called NAME
tmux^Start a new session, named with a number
^
Inside a session — press Ctrl-b, let go, then the key^
Ctrl-b d^Leave it running and go back to the prompt
Ctrl-b s^Switch to another session, from a list
Ctrl-b c^New window; {{Ctrl-b n}} and {{Ctrl-b p}} move between them
Ctrl-b |   Ctrl-b -^Split the window side by side, or top and bottom
Ctrl-b [^Scroll back; {{q}} stops. The mouse wheel works too
exit^Close the shell. The session ends with its last window
^
From another machine^
ssh NAME tmux SESSION^Log in to NAME straight into SESSION
GUIDE
  echo
}
