# `ssh HOST tmux [NAME]` — log in to HOST straight into tmux. Sourced by
# ~/.zshrc on the Macs and by the sys block in ~/.bashrc on Linux, so it must
# stay valid in both zsh and bash.
#
#   ssh mini              an ordinary prompt, as ssh always gives
#   ssh mini tmux         a tmux session no other connection is using, or a new one
#   ssh mini tmux work    the session called "work", started if there is none
#
# Only that exact shape is caught. Anything else — options, other commands,
# scp, rsync, `sys sync all` — goes to the real ssh untouched. -t because ssh
# gives a command no terminal, and tmux will not start without one. The
# session is picked on HOST by ~/.config/tmux/attach.
#
# Installed by sys from ~/.sys/dotfiles/.config/tmux/ssh.sh.

ssh() {
  if [ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ "$2" = tmux ]; then
    case "$1" in -*) command ssh "$@"; return ;; esac
    case "${3-}" in
      *[!A-Za-z0-9_-]*) echo "ssh: a tmux session name is letters, digits, - and _ only" >&2; return 2 ;;
    esac
    command ssh -t "$1" "bash ~/.config/tmux/attach ${3-}"
    return
  fi
  command ssh "$@"
}
