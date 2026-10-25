#!/usr/bin/env bash
# Test harness: runs the REAL conflict-detection awk program extracted from
# start.sh against REAL `tailscale serve status` output.
set -uo pipefail

SCRIPT="${1:?usage: test_serveconflict.sh <start.sh> <serve-status.txt>}"
STATUS_FILE="${2:?usage: test_serveconflict.sh <start.sh> <serve-status.txt>}"

# Extract the program exactly as it lives in start.sh
PROG="$(sed -n "/^SERVE_CONFLICT_AWK='/,/^'\$/p" "$SCRIPT" | sed "1s/^[^']*'//; \$s/'\$//")"
if [ -z "$PROG" ]; then
  echo "FAIL: could not extract SERVE_CONFLICT_AWK from $SCRIPT"
  exit 1
fi
echo "extracted program:"
printf '%s\n' "$PROG" | sed 's/^/    | /'

HOST="hwtdell.tail78bfc5.ts.net"
FAILED=0

run_case() { # run_case <ts_port> <want-target> <expect: conflict|clear>
  local tp="$1" want="$2" expect="$3" out
  out="$(awk -v host="$HOST" -v tp="$tp" -v want="$want" "$PROG" < "$STATUS_FILE")"
  local got="clear"
  [ -n "$out" ] && got="conflict"
  if [ "$got" = "$expect" ]; then
    printf 'PASS  ts_port=%-4s want=%-26s -> %-8s %s\n' "$tp" "$want" "$got" "$out"
  else
    printf 'FAIL  ts_port=%-4s want=%-26s -> %-8s (expected %s) %s\n' "$tp" "$want" "$got" "$expect" "$out"
    FAILED=1
  fi
}

# real status on this host:
#   https://<node>            -> http://127.0.0.1:3080
#   https://<node>:8444       -> http://127.0.0.1:3102
run_case 8444 "http://127.0.0.1:3102" clear     # already ours
run_case 8444 "http://127.0.0.1:9999" conflict  # 8444 taken by someone else
run_case 443  "http://127.0.0.1:3080" clear     # :443 defaults to ours
run_case 443  "http://127.0.0.1:9999" conflict  # :443 taken by someone else
run_case 8443 "http://127.0.0.1:3102" clear     # port not served at all

# an empty status (tailscale serve not configured) must never look like a conflict
: > /tmp/_empty_serve_status.txt
cp /tmp/_empty_serve_status.txt "$STATUS_FILE.empty"
if [ -z "$(awk -v host="$HOST" -v tp=443 -v want=http://127.0.0.1:3080 "$PROG" < "$STATUS_FILE.empty")" ]; then
  echo "PASS  empty serve status -> clear"
else
  echo "FAIL  empty serve status produced a conflict"; FAILED=1
fi
rm -f "$STATUS_FILE.empty" /tmp/_empty_serve_status.txt

[ "$FAILED" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
