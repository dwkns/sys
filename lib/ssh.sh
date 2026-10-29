#!/usr/bin/env bash
# SSH between your own machines, driven by one file in the repo.
#
#   config/ssh/access         who may log in where, and as which account
#   config/ssh/keys/NAME.pub  each machine's public key — safe to publish
#
# Every machine makes its own key once, shares the public half into the repo,
# and on every sync installs the keys the access file lets in and an alias for
# every other machine. Private keys never leave the machine that made them.
# Nothing here ever types a password.

source "${ROOT_DIR:-$HOME/.system-config}/lib/common.sh"
source "${ROOT_DIR:-$HOME/.system-config}/lib/sync.sh"

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_ACCESS="$ROOT_DIR/config/ssh/access"
SSH_KEYS_DIR="$ROOT_DIR/config/ssh/keys"
SSH_HOSTKEYS_DIR="$ROOT_DIR/config/ssh/hostkeys"     # each machine's sshd host key, also public
SSH_NO_SYS="$ROOT_DIR/config/ssh/no-sys"      # machines that cannot run sys; their access is pushed to them
SSH_KNOWN="$HOME/.ssh/known_hosts_sys"        # generated from hostkeys/; NOT under config.d, which ssh reads as config
SSH_HOST_PUB="/etc/ssh/ssh_host_ed25519_key.pub"
SSH_ALIASES="$HOME/.ssh/config.d/sys"                 # generated, safe to delete
SSH_AUTH="$HOME/.ssh/authorized_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-sys-keys-only.conf"
SSH_MARK_START="# >>> sys ssh: from config/ssh/access — keys you add by hand go outside these lines >>>"
SSH_MARK_END="# <<< sys ssh <<<"

ssh_machine()   { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }
ssh_has_key()   { [[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]]; }
ssh_keys_only() { [[ -f "$SSHD_DROPIN" ]] && grep -q '^PasswordAuthentication no' "$SSHD_DROPIN" 2>/dev/null; }
# This machine's sshd host key (public half), so others can pin it.
ssh_host_pub() { [[ -r "$SSH_HOST_PUB" ]] && awk '{print $1, $2}' "$SSH_HOST_PUB"; return 0; }

# Shared means committed, not merely copied into the working tree: the user
# key, and the host key where this machine has one.
ssh_shared() {
  ssh_has_key || return 1
  local me; me="$(ssh_machine)"
  [[ "$(git -C "$ROOT_DIR" show "HEAD:config/ssh/keys/$me.pub" 2>/dev/null)" == "$(cat "$SSH_KEY.pub")" ]] || return 1
  local hk; hk="$(ssh_host_pub)"
  [[ -z "$hk" || "$(git -C "$ROOT_DIR" show "HEAD:config/ssh/hostkeys/$me.pub" 2>/dev/null)" == "$hk" ]]
}

# How many machines the managed block lets in here.
ssh_trusted_count() {
  [[ -f "$SSH_AUTH" ]] || { echo 0; return 0; }
  awk -v s="$SSH_MARK_START" -v e="$SSH_MARK_END" '$0==s{in_=1;next} $0==e{in_=0} in_ && /^ssh-|^ecdsa-|^sk-/{n++} END{print n+0}' "$SSH_AUTH"
}

# The access file with comments and blank lines stripped:  machine account from...
ssh_access_lines() {
  [[ -f "$SSH_ACCESS" ]] && sed 's/#.*//' "$SSH_ACCESS" | awk 'NF'
  return 0
}

# dwkns-mbp-m5 -> mbp-m5: if every machine shares the same first segment it
# is the owner's name, and the alias is what follows. Otherwise the full name.
ssh_prefix() {
  local first p
  first="$(ssh_access_lines | awk 'NR==1{print $1}')"
  [[ "$first" == *-* ]] || return 0
  p="${first%%-*}-"
  if ssh_access_lines | awk -v p="$p" 'index($1,p)!=1 || length($1)<=length(p){bad=1} END{exit bad}'; then
    printf '%s' "$p"
  fi
  return 0
}
ssh_alias() { local p; p="$(ssh_prefix)"; printf '%s' "${1#"$p"}"; }

# ed25519, made here, never copied anywhere. No passphrase, on purpose: the
# disks are encrypted, a headless machine has nobody to type one, and the
# point is that `ssh mini-m1` just works.
ssh_make_key() {
  ssh_has_key && return 0
  doing "Making this machine's SSH key"
  run mkdir -p "$HOME/.ssh"
  run chmod 700 "$HOME/.ssh"
  run ssh-keygen -q -t ed25519 -a 100 -N "" -C "${USER:-$(id -un)}@$(ssh_machine)" -f "$SSH_KEY"
}

# Put this machine's public keys into the repo and push them: the user key
# (so it can log in elsewhere) and the sshd host key (so others can pin it and
# never have to trust a first contact). The one thing sync commits on its own:
# both are safe to publish and always this machine's own. Committed by path,
# so nothing else you have edited rides along.
ssh_share_key() {
  ssh_has_key || return 0
  local me dst hdst hk; me="$(ssh_machine)"; dst="$SSH_KEYS_DIR/$me.pub"; hdst="$SSH_HOSTKEYS_DIR/$me.pub"
  ssh_shared && return 0
  doing "Sharing this machine's public keys as config/ssh/keys/$me.pub and hostkeys/$me.pub"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
  hk="$(ssh_host_pub)"
  # A machine that cannot push (no gh, no login) must not leave the files
  # lying in the working tree either — an untracked copy of a file someone
  # then commits elsewhere makes every later pull refuse.
  if ! is_macos && ! has_cmd gh; then
    warn "This machine cannot push to GitHub. On a Mac, paste these into the repo, then {{sys push}}:"
    note "config/ssh/keys/$me.pub:      $(cat "$SSH_KEY.pub")"
    [[ -n "$hk" ]] && note "config/ssh/hostkeys/$me.pub:  $hk"
    return 0
  fi
  mkdir -p "$SSH_KEYS_DIR" "$SSH_HOSTKEYS_DIR" && cp "$SSH_KEY.pub" "$dst"
  [[ -n "$hk" ]] && printf '%s\n' "$hk" > "$hdst"
  git -C "$ROOT_DIR" add -- "$dst" ${hk:+"$hdst"}
  # An identity of its own: a machine with no .gitconfig (Ubuntu) has none.
  if ! git -C "$ROOT_DIR" -c user.name=sys -c "user.email=sys@$me" \
         commit -q -m "Add SSH keys for $me" -- "$dst" ${hk:+"$hdst"} >/dev/null 2>&1; then
    git -C "$ROOT_DIR" reset -q -- "$dst" ${hk:+"$hdst"} 2>/dev/null; rm -f "$dst" ${hk:+"$hdst"}
    warn "Could not commit the keys — nothing shared"; return 0
  fi
  if push_repo; then
    ok "Keys shared — other machines pick them up on their next {{sys sync}}"
  else
    note "The keys are committed here and will be pushed by the next {{sys sync}} that can"
  fi
  return 0
}

# ~/.ssh/authorized_keys: one managed block holding the keys of the machines
# the access file lets in here. Anything outside the block is left alone,
# except a loose copy of a key the block now carries.
ssh_install_access() {
  local quiet="${1:-}" me row m f want="" missing="" names=""
  me="$(ssh_machine)"
  row="$(ssh_access_lines | awk -v m="$me" '$1==m{print; exit}')"
  if [[ -z "$row" ]]; then
    # Not quiet: a machine outside the file is the commonest mistake, and the
    # only symptom would otherwise be "nobody can log in".
    warn "$me is not in config/ssh/access — nothing is let in here. Add a line for it, {{sys push}}, {{sys sync}}"
    return 0
  fi
  set -- $row
  [[ $# -ge 2 ]] || { warn "config/ssh/access: the line for $me needs an account name"; return 0; }
  shift 2
  for m in "$@"; do
    f="$SSH_KEYS_DIR/$m.pub"
    if [[ -s "$f" ]]; then
      want="$want$(head -1 "$f")"$'\n'; names="$names $(ssh_alias "$m")"
    else
      missing="$missing $(ssh_alias "$m")"
    fi
  done

  local outside="" new
  [[ -f "$SSH_AUTH" ]] && outside="$(awk -v s="$SSH_MARK_START" -v e="$SSH_MARK_END" \
      '$0==s{in_=1;next} $0==e{in_=0;next} !in_' "$SSH_AUTH")"
  if [[ -n "$want" ]]; then
    # awk -v cannot carry newlines, so pass just the key material, space-separated.
    local have; have="$(printf '%s' "$want" | awk '{print $2}' | tr '\n' ' ')"
    outside="$(printf '%s\n' "$outside" | awk -v have="$have" '
      BEGIN{n=split(have,k," "); for(i=1;i<=n;i++) if(k[i]!="") h[k[i]]=1}
      !($2 in h)')"
  fi
  outside="$(printf '%s\n' "$outside" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"   # trim trailing blanks
  new="$(printf '%s\n\n%s\n%s%s\n' "$outside" "$SSH_MARK_START" "$want" "$SSH_MARK_END" | sed '/./,$!d')"

  if [[ -f "$SSH_AUTH" && "$(cat "$SSH_AUTH")" == "$new" ]]; then
    [[ -z "$quiet" ]] && ok "Let in here:${names:- nobody}"
  else
    doing "Letting in:${names:- nobody}"
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      printf '%s\n' "$new" > "$SSH_AUTH.tmp" && mv "$SSH_AUTH.tmp" "$SSH_AUTH" && chmod 600 "$SSH_AUTH"
    fi
  fi
  [[ -n "$missing" ]] && note "No key in the repo yet for:$missing — run {{sys sync}} there"
  return 0
}

# ~/.ssh/known_hosts_sys: every other machine's host key from the
# repo, under the name HostKeyAlias uses, so a wrong machine is refused and
# the first contact needs no "are you sure?".
ssh_write_known_hosts() {
  local quiet="${1:-}" me m out="" f
  me="$(ssh_machine)"
  while read -r m _; do
    [[ "$m" == "$me" ]] && continue
    f="$SSH_HOSTKEYS_DIR/$m.pub"
    [[ -s "$f" ]] && out="$out$m $(head -1 "$f")"$'\n'
  done < <(ssh_access_lines)
  if [[ -f "$SSH_KNOWN" && "$(cat "$SSH_KNOWN")" == "$(printf '%s' "$out")" ]]; then return 0; fi
  [[ "${DRY_RUN:-0}" == "1" ]] && { note "dry run: write $SSH_KNOWN"; return 0; }
  mkdir -p "$HOME/.ssh/config.d" && chmod 700 "$HOME/.ssh" "$HOME/.ssh/config.d"
  printf '%s' "$out" > "$SSH_KNOWN" && chmod 600 "$SSH_KNOWN"
  return 0
}

# ~/.ssh/config.d/sys: an alias, address and account for every other machine
# in the access file. ~/.ssh/config gets one Include line at the top; the rest
# of it is yours.
ssh_write_aliases() {
  local quiet="${1:-}" me cfg="$HOME/.ssh/config" inc="Include config.d/*" all="" out a strict
  me="$(ssh_machine)"
  out="# Written by sys from config/ssh/access. Do not edit — sys sync rewrites it."$'\n'
  out="$out# Hand-written hosts belong in ~/.ssh/config, which includes this file."$'\n'
  # Two routes per machine. The Match line wins when the Tailscale name
  # answers on port 22; otherwise the Host block's NAME.local is used, which
  # works on the home network with Tailscale off. HostKeyAlias makes both
  # routes share one pinned host key. A machine whose host key is not in the
  # repo yet is accepted on first contact, as before, until it is.
  while read -r m account _; do
    [[ "$m" == "$me" ]] && continue
    a="$(ssh_alias "$m")"; all="$all $a"
    # Pinned: only the repo's copy of the host key counts, so a stale entry in
    # the ordinary known_hosts can never vouch for an impostor. Not pinned
    # yet: the ordinary file, accepted on first contact, as before.
    if [[ -s "$SSH_HOSTKEYS_DIR/$m.pub" ]]; then
      strict="  StrictHostKeyChecking yes"$'\n'"  UserKnownHostsFile ~/.ssh/known_hosts_sys"
    else
      strict="  StrictHostKeyChecking accept-new"$'\n'"  UserKnownHostsFile ~/.ssh/known_hosts"
    fi
    out="$out"$'\n'"Match originalhost $a exec \"$ROOT_DIR/bin/ssh-reach $m\""$'\n'"  HostName $m"$'\n'
    out="$out"$'\n'"Host $a"$'\n'"  HostName $m.local"$'\n'"  User $account"$'\n'"  HostKeyAlias $m"$'\n'"$strict"$'\n'
  done < <(ssh_access_lines)
  [[ -n "$all" ]] || { [[ -z "$quiet" ]] && note "No other machines in config/ssh/access"; return 0; }
  out="$out"$'\n'"Host$all"$'\n'
  # Keys only, from these aliases: a machine that refuses the key is either
  # not allowed by config/ssh/access or an impostor, and neither should ever
  # see a password typed at it. Plain `ssh user@host` still can.
  out="$out  IdentityFile ~/.ssh/id_ed25519"$'\n'"  IdentitiesOnly yes"$'\n'
  # Never ask an SSH agent: these machines use their own key, made here and
  # never copied. IdentitiesOnly does not stop ssh consulting an agent first,
  # so a 1Password agent that had frozen after an update hung every login
  # here with nothing on screen. This file is included before anything in
  # ~/.ssh/config, and ssh takes the first value it finds, so this wins over a
  # `Host *` agent line there without stopping it for other hosts.
  out="$out  IdentityAgent none"$'\n'
  # Bound the connect for a hand-typed `ssh mini-m1` too, not just sys's own.
  out="$out  ConnectTimeout 5"$'\n'
  out="$out  PasswordAuthentication no"$'\n'"  KbdInteractiveAuthentication no"$'\n'

  out="$out  ServerAliveInterval 30"$'\n'"  ControlMaster auto"$'\n'"  ControlPath ~/.ssh/cm-%C"$'\n'"  ControlPersist 10m"

  if [[ -f "$SSH_ALIASES" && "$(cat "$SSH_ALIASES")" == "$out" ]]; then
    [[ -z "$quiet" ]] && ok "Aliases:$all"
    return 0
  fi
  doing "Aliases:$all"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$HOME/.ssh/config.d" && chmod 700 "$HOME/.ssh" "$HOME/.ssh/config.d"
  printf '%s\n' "$out" > "$SSH_ALIASES" && chmod 600 "$SSH_ALIASES"
  if [[ ! -f "$cfg" ]]; then
    printf '%s\n' "$inc" > "$cfg" && chmod 600 "$cfg"
  elif ! grep -qxF "$inc" "$cfg"; then
    # Prepend: an Include inside a Host block would only apply to that host.
    { printf '%s\n\n' "$inc"; cat "$cfg"; } > "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && chmod 600 "$cfg"
  fi
}

# Terminal descriptions the machines need to know about each other's
# terminals: Ghostty sets TERM=xterm-ghostty, and a machine you ssh into
# answers "unknown terminal type" until it has the description. Each file in
# config/terminfo is compiled into ~/.terminfo here, once.
install_terminfo() {
  local f name
  has_cmd tic || return 0
  for f in "$ROOT_DIR"/config/terminfo/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    infocmp "$name" >/dev/null 2>&1 && continue
    doing "Teaching this machine about the $name terminal"
    run tic -x -o "$HOME/.terminfo" "$f" 2>/dev/null || warn "Could not compile $name"
  done
  return 0
}

# `sys sync all`: after syncing here, run sys sync on every machine this one
# may log into, per the access file, one after another. Unreachable machines
# are skipped with a note; the rest report as themselves.
ssh_sync_others() {
  local me m a rc=0 targets
  me="$(ssh_machine)"
  targets="$(ssh_access_lines | awk -v me="$me" '{for(i=3;i<=NF;i++) if($i==me) print $1}')"
  # Machines that cannot run sys are configured by ssh_push_access instead.
  targets="$(printf '%s\n' $targets | while read -r m; do ssh_is_no_sys "$m" || printf '%s\n' "$m"; done)"
  [[ -n "$targets" ]] || { note "config/ssh/access lets $me into no other machine"; return 0; }
  for m in $targets; do
    a="$(ssh_alias "$m")"
    header "🔄" "sys sync on $a" "" "$WHITE"
    if ! "$ROOT_DIR/bin/ssh-reach" "$m" && ! "$ROOT_DIR/bin/ssh-reach" "$m.local"; then
      note "$a is not reachable right now — skipped"; continue
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: {{ssh $a sys sync}}"; continue
    fi
    # Log in once, within 15s, before the real run. The sync itself can rightly
    # take many minutes, so it cannot have a total limit — but a login that
    # never completes must not hang `sys sync all` silently.
    if ! timed 15 ssh -o BatchMode=yes "$a" true 2>/dev/null; then
      warn "$a: could not log in within 15s — skipped"; rc=1; continue
    fi
    # -t: a real terminal there, so a one-time GitHub sign-in can show its code.
    if ssh -t -o BatchMode=yes -o ConnectTimeout=8 "$a" \
         'test -x ~/.system-config/bin/sys && exec ~/.system-config/bin/sys sync; echo "sys is not installed here"; exit 99'; then
      :
    else
      case $? in
        99)  warn "$a: sys is not installed there yet — run its setup command on it once" ;;
        255) warn "$a: could not log in — is this machine let in there?" ;;
        *)   warn "$a: {{sys sync}} had problems there (see above)" ;;
      esac
      rc=1
    fi
  done
  return $rc
}

# Machines that cannot run sys (config/ssh/no-sys), one name per line.
ssh_no_sys_list() {
  [[ -f "$SSH_NO_SYS" ]] && sed 's/#.*//' "$SSH_NO_SYS" | awk 'NF{print $1}'
  return 0
}
ssh_is_no_sys() { ssh_no_sys_list | grep -qx "$1"; }

# For each machine that cannot run sys: write its authorized_keys over SSH,
# from the same access file everything else comes from. Only a machine the
# access file lets in there can do it, and one key has to be in place by hand
# first — otherwise there would be no way in to write the file with.
ssh_push_access() {
  local quiet="${1:-}" me m a row keys names f out payload
  me="$(ssh_machine)"
  while read -r m; do
    [[ -n "$m" ]] || continue
    row="$(ssh_access_lines | awk -v m="$m" '$1==m{print; exit}')"
    [[ -n "$row" ]] || continue
    # Not allowed in there ourselves? Then it is not ours to configure.
    printf '%s' "$row" | awk -v me="$me" '{for(i=3;i<=NF;i++) if($i==me) f=1} END{exit !f}' || continue

    keys=""; names=""
    set -- $row; shift 2
    for f in "$@"; do
      [[ -s "$SSH_KEYS_DIR/$f.pub" ]] || continue
      keys="$keys$(head -1 "$SSH_KEYS_DIR/$f.pub")"$'\n'
      names="$names $(ssh_alias "$f")"
    done
    [[ -n "$keys" ]] || continue

    a="$(ssh_alias "$m")"
    "$ROOT_DIR/bin/ssh-reach" "$m" || "$ROOT_DIR/bin/ssh-reach" "$m.local" || {
      [[ -z "$quiet" ]] && note "$a is not reachable — its access was not updated"
      continue
    }
    if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: write authorized_keys on $a for:$names"; continue; fi

    # ssh re-parses the remote command through a shell, so a multi-line
    # argument would arrive as several commands. One base64 blob instead:
    # marker, marker, then the keys.
    payload="$(printf '%s\n%s\n%s' "$SSH_MARK_START" "$SSH_MARK_END" "$keys" | base64 | tr -d '\n')"
    out="$(timed 30 ssh -o BatchMode=yes -o ConnectTimeout=8 "$a" /bin/sh -s -- "$payload" <<'REMOTE' 2>&1
blob=$(printf '%s' "$1" | base64 -d) || { echo "could not decode"; exit 1; }
start=$(printf '%s\n' "$blob" | sed -n 1p)
end=$(printf '%s\n' "$blob" | sed -n 2p)
want=$(printf '%s\n' "$blob" | sed -n '3,$p')
auth="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
outside=""
[ -f "$auth" ] && outside=$(awk -v s="$start" -v e="$end" '$0==s{i=1;next} $0==e{i=0;next} !i' "$auth")
# Drop any loose copy of a key the block now carries, so it is not let in twice.
have=$(printf '%s\n' "$want" | awk '{print $2}' | tr '\n' ' ')
outside=$(printf '%s\n' "$outside" | awk -v have="$have" '
  BEGIN{n=split(have,k," "); for(i=1;i<=n;i++) if(k[i]!="") h[k[i]]=1}
  !($2 in h)' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
new=$(printf '%s\n\n%s\n%s\n%s\n' "$outside" "$start" "$want" "$end" | sed '/./,$!d')
if [ -f "$auth" ] && [ "$(cat "$auth")" = "$new" ]; then echo unchanged; exit 0; fi
printf '%s\n' "$new" > "$auth.sys.tmp" && mv "$auth.sys.tmp" "$auth" && chmod 600 "$auth" && echo changed
REMOTE
)" || { warn "$a: could not update its access — $out"; continue; }

    case "$out" in
      unchanged) [[ -z "$quiet" ]] && ok "$a lets in:$names" ;;
      changed)   doing "$a now lets in:$names" ;;
      *)         warn "$a: unexpected reply — $out" ;;
    esac
  done < <(ssh_no_sys_list)
  return 0
}

# Everything, in order. Run by setup and by every sync.
ssh_apply() {
  local quiet="${1:-}"
  if [[ ! -f "$SSH_ACCESS" ]]; then
    [[ -z "$quiet" ]] && note "No config/ssh/access in the repo — SSH access not managed"
    return 0
  fi
  ssh_make_key || warn "Could not make an SSH key"
  ssh_share_key
  ssh_install_access "$quiet"
  ssh_write_known_hosts "$quiet"
  ssh_write_aliases "$quiet"
  ssh_push_access "$quiet"
  install_terminfo
  return 0
}

# `sys ssh NAME`: log in and attach a session nobody else is using, so losing the
# connection costs nothing — tmux keeps the session running on the machine and
# you pick it up where you left it. Takes the alias or the full machine name.
ssh_connect() {
  local want="$1" m a found="" remote
  while read -r m _; do
    [[ "$m" == "$want" || "$(ssh_alias "$m")" == "$want" ]] && { found="$m"; break; }
  done < <(ssh_access_lines)
  [[ -n "$found" ]] || die "No machine called $want in config/ssh/access — {{sys ssh}} lists them"
  a="$(ssh_alias "$found")"

  # Through a login shell: a non-interactive ssh command gets a bare PATH, so
  # Homebrew's tmux would look missing and this would quietly hand back a
  # plain shell. No tmux there at all? Then a login shell, not an error.
  # The session is picked by ~/.config/tmux/attach, the same rule a plain ssh
  # login uses; a machine not synced since that file arrived gets `main`.
  remote='exec bash -lc '"'"'command -v tmux >/dev/null 2>&1 || exec "$SHELL" -l; [ -r ~/.config/tmux/attach ] && exec bash ~/.config/tmux/attach; exec tmux new -A -s main'"'"''

  if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: connect to $a and attach tmux"; return 0; fi

  exec ssh -t "$a" "$remote"
}

# Lock sshd to keys only. Refuses until at least one key is let in here, so a
# headless machine can never lock itself out. Optional: passwords stay on
# unless you run this.
ssh_harden() {
  local n; n="$(ssh_trusted_count)"
  [[ "$n" -gt 0 ]] || die "No machine is let in here yet — nothing could log in. Check config/ssh/access, then {{sys sync}}"
  grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null \
    || die "This sshd does not include /etc/ssh/sshd_config.d — set PasswordAuthentication no in /etc/ssh/sshd_config by hand"

  local content
  content="$(cat <<'CONF'
# Written by `sys ssh harden`. Keys only — a password cannot be guessed at.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
CONF
)"
  if [[ -f "$SSHD_DROPIN" && "$(cat "$SSHD_DROPIN" 2>/dev/null)" == "$content" ]]; then
    note "sshd: already keys only — $n machine(s) can log in"; return 0
  fi
  doing "Locking sshd to keys only — $n machine(s) can log in"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then note "dry run: write $SSHD_DROPIN and restart sshd"; return 0; fi
  printf '%s\n' "$content" | sudo_run tee "$SSHD_DROPIN" >/dev/null || return 1
  if ! sudo_run /usr/sbin/sshd -t; then
    sudo_run rm -f "$SSHD_DROPIN"
    die "sshd rejected that config — removed it again, nothing changed"
  fi
  if is_macos; then
    # launchd starts one sshd per connection, so open sessions are untouched.
    sudo_run launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  else
    sudo_run systemctl restart ssh 2>/dev/null || sudo_run systemctl restart sshd
  fi
  ok "Password logins off. Only the $n machine(s) in config/ssh/access get in."
}
