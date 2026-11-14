#!/usr/bin/env bash
# sys tmux — the two things about tmux worth a shortcut, and a reminder of
# the rest.
#
#   sys tmux        a short guide
#   sys tmux list   the sessions on this machine
#   sys tmux NAME   go into the session called NAME
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
