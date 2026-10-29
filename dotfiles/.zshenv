# ~/.zshenv — managed by ~/.system-config
#
# Read by EVERY zsh, including the non-interactive ones that `ssh host 'cmd'`
# starts. .zshrc is not: it returns at the top unless the shell is
# interactive. So anything a command sent over SSH needs belongs here, and
# nothing else does — this file runs for every script too.

typeset -U path PATH

# Homebrew on PATH. Without this, `ssh mini 'op …'` (or git, gh, mise…)
# fails with "command not found" while the same command works when you are
# sitting at the machine.
[[ -x /opt/homebrew/bin/brew ]] && path=(/opt/homebrew/bin /opt/homebrew/sbin $path)

# 1Password service account, on the machines that have a token file: it lets
# op read the Dev secrets vault with no one present to approve it.
#
# Guarded on the file existing, which is the point. On a Mac you sit at there
# is no token, so op keeps using the desktop app and Touch ID and can see all
# your vaults. Set this there and op would silently drop to the service
# account, which can see one vault — your personal items would vanish from
# the command line.
[[ -r ~/.op-service-token ]] && export OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.op-service-token)"
