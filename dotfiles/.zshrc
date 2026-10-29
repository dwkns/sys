# ~/.zshrc — managed by ~/.sys
[[ -o interactive ]] || return

# ── PATH ─────────────────────────────────────────────────────────────────────
# typeset -U keeps entries unique, so re-sourcing this file can't bloat PATH.
typeset -U path PATH
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
path=(
  "$HOME/.sys/bin"
  "$HOME/.local/bin"
  "$HOME/.grok/bin"
  "/Applications/Sublime Text.app/Contents/SharedSupport/bin"
  $path
)

# ── Languages ────────────────────────────────────────────────────────────────
# mise replaces rbenv, pyenv, nvm and direnv. Versions: ~/.config/mise/config.toml
command -v mise >/dev/null && eval "$(mise activate zsh)"

# ── History ──────────────────────────────────────────────────────────────────
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS SHARE_HISTORY
setopt EXTENDED_GLOB PROMPT_SUBST

# ── Prompt ───────────────────────────────────────────────────────────────────
# zsh has colours and git status built in — no framework needed.
autoload -Uz colors vcs_info && colors
zstyle ':vcs_info:git:*' formats " on %F{green}%b%f"
precmd() { vcs_info }
# Host name first, in grey: quiet, but you always know which Mac you're on.
# A raw escape rather than %F{8}: zsh looks colours up in terminfo, and over
# ssh an unknown TERM (xterm-ghostty) turns %F{…} into garbage.
PROMPT=$'%{\e[90m%}%m%{\e[39m%} %F{yellow}%~%f${vcs_info_msg_0_}\n$ '

# ── Completions ──────────────────────────────────────────────────────────────
fpath=(~/.config/zsh/completions ~/.grok/completions/zsh $fpath)
autoload -Uz compinit
# -C skips the scan for new completion files, which is what makes shells start
# quickly — so rebuild the cache when sys's own completion is newer than it.
# -i on the rebuild: Homebrew ships a group-writable _ghostty, and without it
# compinit stops dead and you get no completions at all.
if [[ ~/.config/zsh/completions/_sys -nt ~/.zcompdump ]]; then compinit -i; else compinit -C; fi

# ── Environment ──────────────────────────────────────────────────────────────
export EDITOR='code -w'
# Trailing colon makes man append the system manpath, so `man sys` works.
export MANPATH="$HOME/.sys/man:"
export HOMEBREW_CASK_OPTS="--appdir=/Applications"
# Homebrew otherwise checks for updates before almost every command, which
# turns a 2-second install into a 30-second one. Once a month is plenty.
export HOMEBREW_AUTO_UPDATE_SECS=2592000
# And without the paragraph of advice about how to change that.
export HOMEBREW_NO_ENV_HINTS=1
export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a "$USER" -s claude-code-oauth-token -w 2>/dev/null)"

# ── Config ───────────────────────────────────────────────────────────────────
# Guarded so a missing repo degrades quietly instead of erroring every shell.
for f in "$HOME/.sys/lib/common.sh" "$HOME/.aliases" "$HOME/.projects"; do
  [[ -r "$f" ]] && source "$f"
done

# Start new terminals on the Desktop, but not over SSH or inside an IDE.
if [[ -z "$SSH_CONNECTION" && "$PWD" == "$HOME" && "${TERM_PROGRAM:-}" != (vscode|Cursor) ]]; then
  cd ~/Desktop
fi

# ── tmux over SSH ────────────────────────────────────────────────────────────
# An interactive ssh login lands in a tmux session no other connection is
# using, so a dropped connection loses nothing. The rule is in
# ~/.config/tmux/attach. Needs a terminal on both ends, so tools that run the
# shell without one are left alone. Ctrl-b d leaves you at a plain shell.
if [[ -n "$SSH_CONNECTION" && -z "$TMUX" && -t 0 && -t 1 && -r ~/.config/tmux/attach ]]; then
  bash ~/.config/tmux/attach
fi
