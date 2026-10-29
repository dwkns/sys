# shellcheck shell=bash
# `sys tailscale up`: Tailscale on here, then on every machine this one may log
# into. Here first: away from home the tailnet is the only route to the others.
# At home the ssh aliases fall back to NAME.local, so a machine whose Tailscale
# is off is still reachable — which means that from any one machine you can
# get into, the rest can be switched back on.
#
# A machine that cannot run sys (the NAS) is only checked: its Tailscale needs
# sudo, sudo there asks for a password, and an interactive sudo is the user's
# to run. So the run prints the command instead.

# Runs on the machine it reports on, under sh: macOS, Ubuntu or the Synology.
# $1 is "up" (turn it on) or "check" (report only). The last line it prints is
# one word, or a word and a detail: already | on | missing | needs-sudo |
# off <cli path> | failed: <why>.
ts_script() {
  cat <<'SCRIPT'
mode="${1:-up}"
mac=/Applications/Tailscale.app/Contents/MacOS/Tailscale
syno=/var/packages/Tailscale/target/bin/tailscale
sudo=""
if [ -x "$mac" ]; then t="$mac"
elif [ -x "$syno" ]; then t="$syno"; sudo="sudo -n"
elif command -v tailscale >/dev/null 2>&1; then t="$(command -v tailscale)"; sudo="sudo -n"
else echo missing; exit 0
fi
# No JSON (a CLI that will not report status to this user)? Then the test
# sys nas uses: it is up if it has a tailnet address.
running() {
  s="$("$t" status --json 2>/dev/null)"
  if [ -n "$s" ]; then printf '%s\n' "$s" | grep -q '"BackendState": *"Running"'
  else [ -n "$("$t" ip -4 2>/dev/null)" ]
  fi
}
if running; then echo already; exit 0; fi
if [ "$mode" != up ]; then echo "off $t"; exit 0; fi
if [ "$t" = "$mac" ]; then
  # The Mac app must be running for its command-line tool to answer.
  open -a Tailscale 2>/dev/null
elif command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet tailscaled; then
  $sudo systemctl start tailscaled 2>/dev/null || { echo needs-sudo; exit 0; }
fi
# Give the app or the daemon up to ten seconds to answer.
i=0
while [ "$i" -lt 10 ] && ! "$t" status --json >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
# No flags: with none, tailscale up keeps every setting and only reconnects.
out="$($sudo "$t" up --timeout=30s 2>&1)"
if running; then echo on; exit 0; fi
case "$out" in
  *"a password is required"*) echo needs-sudo ;;
  *) echo "failed: $(printf '%s\n' "$out" | grep -v -e '^ *$' -e 'accept-routes' | tail -2 | tr '\n' ' ')" ;;
esac
SCRIPT
}

# One machine's answer, as a line of output. Returns 1 when it is a problem.
ts_report() {
  local a="$1" res="$2"
  case "$res" in
    already)    ok "$a: Tailscale was already on" ;;
    on)         ok "$a: Tailscale is on" ;;
    missing)    warn "$a: Tailscale is not installed there"; return 1 ;;
    needs-sudo) warn "$a: starting Tailscale needs sudo, and sudo asked for a password — run {{sudo tailscale up}} there"; return 1 ;;
    off\ /var/packages/*)
                note "$a: Tailscale is off. It needs your password there: {{ssh -t $a 'sudo synopkg start Tailscale; sudo ${res#off } up'}}" ;;
    off\ *)     note "$a: Tailscale is off. Turn it on there: {{ssh -t $a 'sudo ${res#off } up'}}" ;;
    failed:*)   warn "$a: Tailscale did not come on — ${res#failed: }"; return 1 ;;
    *)          warn "$a: unexpected reply — ${res:-nothing}"; return 1 ;;
  esac
  return 0
}

tailscale_up_all() {
  local me m a mode res code rc=0 targets
  me="$(ssh_machine)"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    note "dry run: turn Tailscale on here"
  else
    res="$(ts_script | sh -s up 2>/dev/null | tail -1)" || true
    ts_report "$(ssh_alias "$me")" "$res" || rc=1
  fi

  targets="$(ssh_access_lines | awk -v me="$me" '{for(i=3;i<=NF;i++) if($i==me) print $1}')"
  [[ -n "$targets" ]] || { note "config/ssh/access lets $me into no other machine"; return $rc; }

  for m in $targets; do
    a="$(ssh_alias "$m")"
    if ! "$ROOT_DIR/bin/ssh-reach" "$m" && ! "$ROOT_DIR/bin/ssh-reach" "$m.local"; then
      note "$a is not reachable right now — skipped"; continue
    fi
    mode=up; ssh_is_no_sys "$m" && mode=check
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      if [[ "$mode" == up ]]; then note "dry run: turn Tailscale on at $a"; else note "dry run: check Tailscale at $a"; fi
      continue
    fi
    # One login per machine, bounded: a machine that never answers must not
    # hang the run. The script travels on stdin, so nothing needs quoting.
    code=0
    res="$(timed 60 ssh -o BatchMode=yes -o ConnectTimeout=8 "$a" sh -s -- "$mode" 2>/dev/null < <(ts_script))" || code=$?
    case "$code" in
      0)   ts_report "$a" "$(printf '%s\n' "$res" | tail -1)" || rc=1 ;;
      142) warn "$a: no answer within 60s"; rc=1 ;;
      255) warn "$a: could not log in — is this machine let in there?"; rc=1 ;;
      *)   warn "$a: the check failed (exit $code)"; rc=1 ;;
    esac
  done
  return $rc
}
