#!/usr/bin/env bash
# The NAS, from config/nas.
#
#   sys nas        what it is, how to reach it, what it holds, and its health
#   sys nas open   its admin web page, in the browser here
#
# Everything is read live over one SSH call, as dwkns, without root — so it
# shows what is true now, and it can never type a password.

source "${ROOT_DIR:-$HOME/.sys}/lib/common.sh"

NAS_FILE="$ROOT_DIR/config/nas"

nas_get() {
  [[ -f "$NAS_FILE" ]] && sed 's/#.*//' "$NAS_FILE" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ +/, ""); print; exit }'
  return 0
}

# "1338 GB" from kilobytes, without needing bc.
nas_size() { awk -v k="$1" 'BEGIN { g = k / 1024 / 1024; if (g >= 1000) printf "%.2f TB", g / 1024; else if (g >= 1) printf "%.0f GB", g; else printf "%.0f MB", k / 1024 }'; }

nas_open() {
  local web; web="$(nas_get web)"
  [[ -n "$web" ]] || die "No web address in config/nas"
  doing "Opening $web"
  if is_macos; then open "$web"; else xdg-open "$web" >/dev/null 2>&1 || note "Open $web in a browser"; fi
}

nas_show() {
  local host alias web
  host="$(nas_get host)"; web="$(nas_get web)"
  [[ -n "$host" ]] || die "No host in config/nas"
  alias="$(ssh_alias "$host")"

  # Same layout as sys doctor: a white label, then the state in its colour.
  row()  { printf '  %s%-11s%s %s\n' "$WHITE" "$1" "$RESET" "$2"; }
  good() { printf '%s%s%s' "$GREEN" "$1" "$RESET"; }
  bad()  { printf '%s%s%s' "$RED" "$1" "$RESET"; }
  off()  { printf '%s%s%s' "$ORANGE" "$1" "$RESET"; }
  grey() { printf '%s%s%s' "$GREY" "$1" "$RESET"; }

  header "💾" "NAS — $host"

  # How to reach it, from here. Tailscale being off is a choice, not a fault.
  local ts_here=0 route
  if tailscale_running_here; then ts_here=1; fi
  if "$ROOT_DIR/bin/ssh-reach" "$host.local"; then route="$(good "local network ✓")"
  else route="$(bad "local network ✗")"; fi
  if "$ROOT_DIR/bin/ssh-reach" "$host"; then route="$route  $(good "tailnet ✓")"
  elif [[ "$ts_here" == "0" ]]; then route="$route  $(off "tailnet ✗") $(grey "— Tailscale is off here")"
  else route="$route  $(bad "tailnet ✗")"; fi
  row "Reach" "$route"
  row "Commands" "$(printf '%sssh %s%s%s  ·  %ssys nas open%s%s  ·  %ssys net%s' \
      "$WHITE" "$alias" "$RESET" "$GREY" "$WHITE" "$RESET" "$GREY" "$WHITE" "$RESET")"

  # Everything else in one SSH call, as key=value lines.
  local facts
  if ! facts="$(timed 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$alias" 'sh -s' 2>/dev/null <<'REMOTE'
. /etc/VERSION 2>/dev/null
echo "model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null)"
echo "dsm=$productversion build $buildnumber"
echo "up=$(uptime | sed -n 's/.* up \([^,]*\),.*/\1/p')"
df -kP /volume1 2>/dev/null | awk 'NR == 2 { print "vol=" $3 " " $2 }'
root="$(df -P / | awk 'NR == 2 { print $1 }')"
for v in /volumeUSB*/usbshare*; do
  [ -d "$v" ] || continue
  df -kPT "$v" 2>/dev/null | awk -v v="$v" -v root="$root" 'NR == 2 {
    print "usb=" v "|" ($1 == root ? "unmounted" : $2) "|" $3 "|" $4 }'
done
awk '/^\[/ { n = substr($0, 2, length($0) - 2) } /^\tpath=/ { sub(/^\tpath=/, ""); print "share=" n "|" $0 }' /etc/samba/smb.share.conf 2>/dev/null
ip="$(/var/packages/Tailscale/target/bin/tailscale ip -4 2>/dev/null | head -1)"
echo "ts=${ip:-stopped}"
REMOTE
)"; then
    row "SSH" "$(bad "could not log in within 20s") $(grey "— is it on, and is this machine in config/ssh/access?")"
    echo; return 1
  fi

  get() { printf '%s\n' "$facts" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

  row "Model" "$(get model) $(grey "· DSM $(get dsm) · up $(get up)")"

  local used total
  read -r used total <<<"$(get vol)"
  [[ -n "$total" ]] && row "Disk" "$(nas_size "$used") of $(nas_size "$total") $(grey "used ($(( used * 100 / total ))%)")"

  local ts; ts="$(get ts)"
  if [[ "$ts" == "stopped" ]]; then
    row "Tailscale" "$(bad "stopped on the NAS") $(grey "— see docs/nas.md")"
  else
    row "Tailscale" "$(good running) $(grey "· $ts")"
  fi

  # Shares, with any USB drive shown against the share that serves it.
  echo
  printf '  %sShares%s\n' "$WHITE" "$RESET"
  local name path line
  while IFS= read -r line; do
    name="${line%%|*}"; path="${line#*|}"
    local note="" usb
    usb="$(printf '%s\n' "$facts" | awk -F'[=|]' -v p="$path" '$1 == "usb" && $2 == p { print $3 "|" $4 "|" $5; exit }')"
    if [[ -n "$usb" ]]; then
      local fs size uused; IFS='|' read -r fs size uused <<<"$usb"
      if [[ "$fs" == "unmounted" ]]; then
        note="$(bad "USB drive not mounted") $(grey "— nothing to write to here")"
      elif [[ "$fs" == "vfat" && "$size" -lt 1048576 ]]; then
        # The small boot partition every GPT-formatted drive carries. DSM
        # shares it automatically; there is nothing on it.
        note="$(grey "the USB drive's boot partition — empty, ignore it")"
      else
        note="$(grey "USB drive · $fs · $(nas_size "$uused") of $(nas_size "$size") used")"
      fi
    elif [[ "$path" == /volume1/* ]]; then
      note="$(grey "internal disk")"
    fi
    printf '    %s%-20s%s %s\n' "$WHITE" "$name" "$RESET" "$note"
  done < <(printf '%s\n' "$facts" | awk -F= '$1 == "share" { sub(/^share=/, ""); print }')

  echo
  printf '  %sMore: docs/nas.md · web page %s%s%s\n\n' "$GREY" "$WHITE" "$web" "$RESET"
}

# Is Tailscale running on THIS machine? Decides orange versus red for the
# tailnet route: off here is your choice, off there is a fault.
tailscale_running_here() {
  local t
  for t in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    command -v "$t" >/dev/null 2>&1 || [[ -x "$t" ]] || continue
    "$t" status --json 2>/dev/null | grep -q '"BackendState": *"Running"' && return 0
    return 1
  done
  return 1
}
