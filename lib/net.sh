#!/usr/bin/env bash
# Network shares, from config/net.
#
#   sys net         list them, and say which are mounted
#   sys net NAME    connect to one
#
# Connecting is handed to Finder (`open smb://…`), which is the only thing on
# the Mac that can read the saved password: the Keychain item Finder writes is
# locked to Finder and NetAuthAgent, so smbutil and mount_smbfs are refused and
# would fall back to asking. Nothing here reads, stores or types a password.

source "${ROOT_DIR:-$HOME/.sys}/lib/common.sh"

NET_FILE="$ROOT_DIR/config/net"

# name|url|description per line, comments and blanks stripped, spaces trimmed.
net_lines() {
  [[ -f "$NET_FILE" ]] || return 0
  sed 's/#.*//' "$NET_FILE" | awk -F'|' 'NF>=2 {
    for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
    if ($1 != "" && $2 != "") print $1 "|" $2 "|" $3
  }'
  return 0
}

# smb://dwkns@192.168.5.45/Share -> //dwkns@192.168.5.45/Share, as mount(8)
# prints it. No share given means "the server", which matches any share on it.
net_mount_of() {
  local url="$1" body
  body="${url#*://}"
  mount | awk -v want="//$body" '
    $1 == want || index($1, want "/") == 1 {
      for (i = 1; i <= NF; i++) if ($i == "on") { p = $(i+1); for (j = i+2; j < NF; j++) { if ($j ~ /^\(/) break; p = p " " $j } print p; exit }
    }'
  return 0
}

net_list() {
  local name url desc where any=0
  header "🌐" "Network shares"
  while IFS='|' read -r name url desc; do
    any=1
    where="$(net_mount_of "$url")"
    if [[ -n "$where" ]]; then
      printf '    %ssys net %-12s%s %s→ %s%s  %s%s%s\n' \
        "$WHITE" "$name" "$RESET" "$GREY" "$url" "$RESET" "$GREEN" "mounted at $where" "$RESET"
    else
      printf '    %ssys net %-12s%s %s→ %s%s\n' \
        "$WHITE" "$name" "$RESET" "$GREY" "$url" "$RESET"
    fi
  done < <(net_lines)
  if [[ "$any" == "0" ]]; then
    note "Nothing in config/net yet"
  fi
  echo
  printf '  %sAdd one to %sconfig/net%s%s, then %ssys push%s%s.%s\n\n' \
    "$GREY" "$WHITE" "$RESET" "$GREY" "$WHITE" "$RESET" "$GREY" "$RESET"
}

net_connect() {
  local want="$1" name url desc found="" i where
  while IFS='|' read -r name url desc; do
    [[ "$name" == "$want" ]] && { found="$url"; break; }
  done < <(net_lines)

  if [[ -z "$found" ]]; then
    error "No share called $want in config/net"
    net_list
    return 1
  fi

  where="$(net_mount_of "$found")"
  [[ -n "$where" ]] && { ok "$want is already connected — $where"; return 0; }

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    note "dry run: open $found"
    return 0
  fi

  doing "Connecting to $found"
  open "$found" || { error "Finder could not open $found"; return 1; }

  # Finder mounts in the background, so wait for the volume rather than
  # claiming success the moment open returns.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    where="$(net_mount_of "$found")"
    [[ -n "$where" ]] && { ok "$want connected — $where"; return 0; }
    sleep 1
  done

  # Still nothing: either Finder is asking something, or the password is not
  # in the Keychain on this machine.
  warn "$want did not mount within 15s"
  note "If Finder is asking: pick the share, tick 'Remember this password in my keychain', and it will be silent from then on."
  note "If the url has no share name, add one to config/net: {{$found/ShareName}}"
  return 1
}
