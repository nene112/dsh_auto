#!/usr/bin/env bash
# =============================================================================
#  DeepSeek Harness - Linux one-click setup + start (counterpart of start.ps1)
#
#  What it does, in order:
#    1. environment check   : Linux, arch, Node/npm versions, curl, python3/perl,
#                             systemd, tailscale (online or not)
#    2. dependencies        : npm ci|install if the tree is missing, then repair
#                             npm 11's gated native build steps (node-pty, koffi)
#    3. LAN/Tailscale patches: the same three patches start.ps1 applies, verified
#                             against @deepseek-ai/dsh 0.2.1-rc.3
#    4. trust config        : ~/.dsh/profiles/web/cordis.patch.yml gets the
#                             tailnet authority in the `connection` row, so /api
#                             is not fenced off (403) through tailscale serve
#    5. optional tailnet entry: only with --tailscale; dsh itself stays on
#                             127.0.0.1 and Tailscale is ignored by default
#    6. start               : systemd unit (survives reboot) or foreground
#    7. verify              : page, first-visit token URL, WebSocket mux upgrade
#
#  Usage:
#    ./start.sh                       # check, install, start in the foreground
#    ./start.sh --check-only          # environment report only, changes nothing
#    ./start.sh --diagnose            # read-only: why is the page blank? + verdict
#    ./start.sh --selftest            # zero side effects: test this script's logic
#    sudo ./start.sh --install-service   # install + enable + start a systemd unit
#    sudo ./start.sh --uninstall-service
#
#  Blank page: dsh 0.2.x loads the page HTML even when the browser-trust fence
#  rejects the Host, then every /api call answers 403 and the app renders
#  nothing. --diagnose tells you which of the two blank-page causes it is
#  (403 = trust fence, or 401 = you need the launch-token URL), and
#  --install-service re-run self-heals the 403 case by writing the trust row
#  into the dsh home the unit actually reads and restarting.
#
#  Options:
#    --port N            dsh listen port              (default 3080)
#    --tailscale         enable the optional tailnet HTTPS entry
#    --ts-port N         tailscale serve HTTPS port   (default 443)
#    --no-tailscale      compatibility alias for the default local-only mode
#    --mirror MODE       auto, china, or official     (default auto)
#    --user NAME         user for the systemd unit    (default: $SUDO_USER or $USER)
#    --clone             git clone this repo first when run outside a checkout
#    --force-node        reinstall the private Node runtime even if Node is usable
#    --node-prefix DIR   where a private Node goes    (default <repo>/.runtime/node)
#    --service-name NAME systemd unit name            (default dsh)
#    --force             proceed past a preflight conflict (see below)
#
#  System footprint - everything this script may touch outside its own directory:
#    <repo>/node_modules                     (npm ci; patched afterwards)
#    <node-prefix>                           only when the host has no usable Node
#    <service-user-home>/.dsh/profiles/web/cordis.patch.yml   (one added row)
#    /etc/systemd/system/<service-name>.service               (only with --install-service)
#    `tailscale serve --bg --https=<ts-port>` mapping for this node
#  Preflight refuses to continue when the dsh port is taken by another process,
#  when the tailscale port already serves something else, or when a systemd unit
#  with the same name exists that this script did not write. Nothing is ever
#  killed, no firewall rule is added, and no global package is installed.
#
#  Note (dsh 0.2.x): every request is authenticated. The process prints
#  "dsh web: <url>?token=..." once; the first visit from each device must carry
#  that token, which mints a 30-day signed cookie scoped to that authority. The
#  token is regenerated on every start; existing cookies keep working.
# =============================================================================

set -euo pipefail

PORT=3080
TS_PORT=443
USE_TAILSCALE=0
INSTALL_SERVICE=0
UNINSTALL_SERVICE=0
CHECK_ONLY=0
DO_CLONE=0
FORCE_NODE=0
FORCE=0
SELFTEST=0
DIAGNOSE=0
SERVICE_USER=""
SERVICE_NAME="dsh"
NODE_MAJOR_TARGET="24"
MIRROR_MODE="${DSH_MIRROR:-auto}"
CHINA_NODE_MIRROR="https://npmmirror.com/mirrors/node"
OFFICIAL_NODE_MIRROR="https://nodejs.org/dist"
CHINA_NPM_REGISTRY="https://registry.npmmirror.com"
OFFICIAL_NPM_REGISTRY="https://registry.npmjs.org"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Keep the downloaded runtime inside this checkout. It needs no root access and
# does not shadow a distribution-managed Node installation.
NODE_PREFIX="${DSH_NODE_PREFIX:-$SCRIPT_DIR/.runtime/node}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_STEP=$'\033[36m'
else
  C_RESET=""; C_OK=""; C_WARN=""; C_ERR=""; C_STEP=""
fi

step() { printf '\n%s==> %s%s\n' "$C_STEP" "$*" "$C_RESET"; }
ok()   { printf '%sOK  %s%s\n'   "$C_OK"   "$*" "$C_RESET"; }
warn() { printf '%sWARN %s%s\n'  "$C_WARN" "$*" "$C_RESET"; }
err()  { printf '%sERR %s%s\n'   "$C_ERR"  "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    --ts-port) TS_PORT="${2:?}"; shift 2 ;;
    --tailscale) USE_TAILSCALE=1; shift ;;
    --no-tailscale) USE_TAILSCALE=0; shift ;;
    --mirror) MIRROR_MODE="${2:?}"; shift 2 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --uninstall-service) UNINSTALL_SERVICE=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --clone) DO_CLONE=1; shift ;;
    --force-node) FORCE_NODE=1; shift ;;
    --force) FORCE=1; shift ;;
    --node-prefix) NODE_PREFIX="${2:?}"; shift 2 ;;
    --service-name) SERVICE_NAME="${2:?}"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    --diagnose) DIAGNOSE=1; shift ;;
    --user) SERVICE_USER="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$MIRROR_MODE" in
  auto|china|official) ;;
  *) die "invalid --mirror value '$MIRROR_MODE' (use auto, china, or official)" ;;
esac

# ---------------------------------------------------------------- helpers

version_ge() { # version_ge <have> <need>  -- pure bash: 'sort -V' is missing on BusyBox
  local IFS=. i
  local -a have need
  read -r -a have <<< "$1"
  read -r -a need <<< "$2"
  for i in 0 1 2; do
    local h="${have[$i]:-0}" n="${need[$i]:-0}"
    if [ "$h" -gt "$n" ] 2>/dev/null; then return 0; fi
    if [ "$h" -lt "$n" ] 2>/dev/null; then return 1; fi
  done
  return 0
}

patch_engine() { # -> python3 | perl | none, probed once so a broken tool is not trusted
  if [ -z "${PATCH_ENGINE:-}" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
      PATCH_ENGINE=python3
    elif command -v perl >/dev/null 2>&1 && perl -e '1' >/dev/null 2>&1; then
      PATCH_ENGINE=perl
    elif command -v node >/dev/null 2>&1 && node -e '' >/dev/null 2>&1; then
      PATCH_ENGINE=node
    else
      PATCH_ENGINE=none
    fi
  fi
  printf '%s' "$PATCH_ENGINE"
}

node_usable() { # the engines range is ^22.19.0 || >=24.0.0 (23 is outside)
  command -v node >/dev/null 2>&1 || return 1
  local v major minor
  v="$(node -v 2>/dev/null | sed 's/^v//')"
  [ -n "$v" ] || return 1
  major="${v%%.*}"; minor="$(printf '%s' "$v" | cut -d. -f2)"
  [ "$major" = "23" ] && return 1
  if [ "$major" -gt 23 ] 2>/dev/null; then return 0; fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 19 ] 2>/dev/null; then return 0; fi
  return 1
}

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "need curl or wget to download $1"; fi
}

url_reachable() { # url_reachable <url>
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --max-time 8 "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget --spider -q -T 8 "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

select_npm_registry() {
  case "$MIRROR_MODE" in
    official) printf '%s' "$OFFICIAL_NPM_REGISTRY" ;;
    china)
      if url_reachable "$CHINA_NPM_REGISTRY"; then printf '%s' "$CHINA_NPM_REGISTRY"
      else warn "China npm mirror probe failed; falling back to the official registry" >&2; printf '%s' "$OFFICIAL_NPM_REGISTRY"; fi ;;
    auto)
      if url_reachable "$CHINA_NPM_REGISTRY"; then printf '%s' "$CHINA_NPM_REGISTRY"
      else printf '%s' "$OFFICIAL_NPM_REGISTRY"; fi ;;
  esac
}

node_bases() {
  case "$MIRROR_MODE" in
    official) printf '%s\n' "$OFFICIAL_NODE_MIRROR" ;;
    *) printf '%s\n%s\n' "$CHINA_NODE_MIRROR" "$OFFICIAL_NODE_MIRROR" ;;
  esac
}

fetch_node_file() { # fetch_node_file <relative-path> <dest>; prints the base used
  local rel="$1" dest="$2" base
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if fetch "$base/$rel" "$dest" 2>/dev/null; then printf '%s' "$base"; return 0; fi
    warn "download failed from $base/$rel" >&2
    rm -f "$dest"
  done < <(node_bases)
  return 1
}

clear_owned_node_prefix() {
  [ -n "$NODE_PREFIX" ] || die "node prefix is empty"
  case "$NODE_PREFIX" in /|/usr|/usr/local|/opt|/home|/root) die "refusing unsafe --node-prefix $NODE_PREFIX" ;; esac
  if [ -e "$NODE_PREFIX" ]; then
    [ -f "$NODE_PREFIX/.dsh-auto-node-runtime" ] \
      || die "refusing to replace non-owned directory $NODE_PREFIX; choose an empty --node-prefix or remove it yourself"
    rm -rf -- "$NODE_PREFIX"
  fi
}

# literal string replacement; python3 preferred, perl as fallback. The result is
# verified with grep - a patch that did not land must never report success.
patch_literal() { # patch_literal <file> <old> <new> <marker> <label>
  local file="$1" old="$2" new="$3" marker="$4" label="$5"
  if [ ! -f "$file" ]; then warn "$label: file missing (skip)"; return 1; fi
  if grep -qF -- "$marker" "$file"; then ok "$label: already patched"; return 0; fi
  if ! grep -qF -- "$old" "$file"; then warn "$label: pattern changed upstream (skip)"; return 1; fi
  case "$(patch_engine)" in
    python3)
      python3 - "$file" "$old" "$new" <<'PY' || { err "$label: python3 replacement failed"; return 1; }
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
if sys.argv[2] not in text:
    sys.exit(2)
p.write_text(text.replace(sys.argv[2], sys.argv[3], 1), encoding="utf-8")
PY
      ;;
    perl)
      OLD="$old" NEW="$new" perl -0777 -pi -e 'my $o=$ENV{OLD}; my $n=$ENV{NEW}; s/\Q$o\E/$n/;' "$file" \
        || { err "$label: perl replacement failed"; return 1; }
      ;;
    node)
      local tmp_file="${file}.dsh-auto.tmp"
      if ! OLD="$old" NEW="$new" node -e '
const fs = require("fs");
const oldText = process.env.OLD;
const newText = process.env.NEW;
const text = fs.readFileSync(0, "utf8");
if (!text.includes(oldText)) process.exit(2);
process.stdout.write(text.replace(oldText, newText));
' < "$file" > "$tmp_file"; then
        rm -f "$tmp_file"
        err "$label: node replacement failed"
        return 1
      fi
      mv "$tmp_file" "$file"
      ;;
    *)
      err "$label: no working python3 or perl, cannot patch"; return 1 ;;
  esac
  if ! grep -qF -- "$new" "$file"; then err "$label: replacement did not land"; return 1; fi
  ok "$label: patched"
  return 0
}

tailnet_dns_name() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local json name
  json="$(tailscale status --json 2>/dev/null)" || return 1
  name="$(printf '%s' "$json" | grep -o '"DNSName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  [ -n "$name" ] || return 1
  printf '%s' "${name%.}"
}

# Does the tailscale HTTPS port this run wants already serve something else?
# Prints one "<authority> -> <what it serves>" line per conflict, nothing when
# the port is free or already points at us. Kept in a variable (closing quote on
# its own line) so it can be run against real `tailscale serve status` output:
#   prog="$(sed -n "/^SERVE_CONFLICT_AWK='/,/^'\$/p" start.sh | sed "1s/^SERVE_CONFLICT_AWK='//; \$s/'\$//")"
#   tailscale serve status | awk -v host=NODE -v tp=443 -v want=http://127.0.0.1:3080 "$prog"
SERVE_CONFLICT_AWK='
  BEGIN {
    # port-less "https://host" in serve status means :443, so match it exactly
    auth = (tp == "443") ? ("https://" host) : ("https://" host ":" tp)
  }
  /^\|--/ {
    if (cur == auth || (auth == "https://" host && cur == "https://" host ":443")) {
      if (index($0, want) == 0) print cur " -> " $0
    }
    next
  }
  { cur = $1 }
'

add_trusted_host() { # add_trusted_host <file> <authority>
  # Insert "      - <authority>" right after trustedHosts: inside the connection
  # row, without touching anything else in the file. Pure bash on purpose.
  local file="$1" authority="$2" tmp="$1.startsh.tmp" line in_conn=0 inserted=0
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- id: connection"*) in_conn=1 ;;
      "- id:"*) in_conn=0 ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
    if [ "$in_conn" = "1" ] && [ "$inserted" = "0" ]; then
      case "$line" in
        *"trustedHosts:"*) printf '      - %s\n' "$authority" >> "$tmp"; inserted=1 ;;
      esac
    fi
  done < "$file"
  if [ "$inserted" = "1" ]; then mv "$tmp" "$file"; return 0; fi
  rm -f "$tmp"
  return 1
}

ensure_trust_row() { # ensure_trust_row <dsh_home> <authority>
  # Idempotent: makes sure the `connection` row lists the authority, so the /api
  # browser-trust fence accepts it. Without it the page HTML loads and every API
  # call answers 403 - which renders as a BLANK page in the browser.
  local dsh_home="$1" authority="$2" patch_file
  patch_file="$dsh_home/profiles/web/cordis.patch.yml"
  if grep -q 'id: connection' "$patch_file" 2>/dev/null; then
    if grep -A8 -- '- id: connection' "$patch_file" 2>/dev/null | grep -qF -- "- $authority"; then
      ok "connection row for $authority present in $patch_file"
      return 0
    fi
    warn "connection row exists in $patch_file but does not list $authority - adding it"
    if add_trusted_host "$patch_file" "$authority" && grep -qF -- "- $authority" "$patch_file"; then
      ok "added $authority to the connection row in $patch_file"
      return 0
    fi
    err "could not edit $patch_file - add '      - $authority' under trustedHosts: by hand"
    return 1
  fi
  mkdir -p "$(dirname "$patch_file")"
  [ -f "$patch_file" ] || printf '# dsh profile patch layer, written by start.sh\n[]\n' > "$patch_file"
  if grep -vE '^\s*(#|$)' "$patch_file" | grep -q '^\[\]\s*$'; then
    printf '# dsh profile patch layer, written by start.sh\n' > "$patch_file"
  fi
  cat >> "$patch_file" <<EOF

# Tailscale entry (added by start.sh): tailscale serve forwards the ORIGINAL
# tailnet Host header, so the /api browser-trust fence in the \`connection\` row
# rejects every request with 403 unless that authority is declared here. Doing
# it in config (not via --trusted-host) means any launch path gets it right.
- id: connection
  config:
    trustedHosts:
      - $authority
EOF
  if grep -qF -- "- $authority" "$patch_file"; then
    ok "added the connection row for $authority to $patch_file"
    return 0
  fi
  err "failed to write the connection row to $patch_file"
  return 1
}

# ---------------------------------------------------------------- self-test

if [ "$SELFTEST" = "1" ]; then
  step "Self-test of this script's helpers (touches nothing outside a temp dir)"
  FAIL=0
  if version_ge 24.0.0 22.19.0; then ok "version_ge accepts 24.0.0 >= 22.19.0"; else err "version_ge broke on a newer major"; FAIL=1; fi
  if version_ge 22.0.0 22.19.0; then err "version_ge wrongly accepted 22.0.0 >= 22.19.0"; FAIL=1; else ok "version_ge rejects 22.0.0 < 22.19.0"; fi
  if version_ge 22.19.0 22.19.0; then ok "version_ge treats equality as satisfied"; else err "version_ge broke on equality"; FAIL=1; fi
  if version_ge 22.19.0 24.0.0; then err "version_ge wrongly accepted 22.19.0 >= 24.0.0"; FAIL=1; else ok "version_ge rejects a lower major"; fi
  if command -v node >/dev/null 2>&1; then
    if node_usable; then ok "node_usable($(node -v)) -> true"; else warn "node_usable($(node -v)) -> false (the installer would take over)"; fi
  fi

  if [ "$(patch_engine)" = "none" ]; then
    warn "no working python3/perl here, so the patch assertions are skipped (they run on the server)"
  else
    TMPT="$(mktemp -d)"
    OLD='const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";'
    printf '%s\n' "$OLD" > "$TMPT/a.js"
    if patch_literal "$TMPT/a.js" "$OLD" 'const persistence = "host"; // patched' 'patched' "selftest"; then
      ok "patch_literal handled a literal containing quotes and a dollar sign"
    else
      err "patch_literal failed on the literal"; FAIL=1
    fi
    if grep -qF 'const persistence = "host"; // patched' "$TMPT/a.js"; then ok "the replacement landed verbatim"; else err "replacement missing"; FAIL=1; fi
    if patch_literal "$TMPT/a.js" "$OLD" 'other' 'patched' "selftest-idempotent"; then ok "patch_literal is idempotent via its marker"; else err "idempotency broke"; FAIL=1; fi
    if patch_literal "$TMPT/a.js" 'a pattern that is not there' 'x' 'never' "selftest-missing"; then
      err "patch_literal wrongly reported success for a vanished pattern"; FAIL=1
    else
      ok "patch_literal reports a vanished pattern as a skip (not a silent pass)"
    fi
    if grep -qF 'other' "$TMPT/a.js"; then err "the skipped patch still modified the file"; FAIL=1; else ok "a skipped patch leaves the file untouched"; fi
    rm -rf "$TMPT"
  fi

  # trust-row logic (the part that prevents the blank page)
  TMPT="$(mktemp -d)"
  HOMEDIR="$TMPT/home/.dsh"
  ensure_trust_row "$HOMEDIR" "node1.example.ts.net" >/dev/null 2>&1
  if grep -q -- '- id: connection' "$HOMEDIR/profiles/web/cordis.patch.yml" 2>/dev/null \
     && grep -qF -- '- node1.example.ts.net' "$HOMEDIR/profiles/web/cordis.patch.yml"; then
    ok "ensure_trust_row creates the row for a fresh home"
  else
    err "ensure_trust_row did not create the row"; FAIL=1
  fi
  ensure_trust_row "$HOMEDIR" "node1.example.ts.net" >/dev/null 2>&1
  N=$(grep -c -- '- id: connection' "$HOMEDIR/profiles/web/cordis.patch.yml" 2>/dev/null)
  A=$(grep -cF -- '- node1.example.ts.net' "$HOMEDIR/profiles/web/cordis.patch.yml" 2>/dev/null)
  if [ "${N:-0}" = "1" ] && [ "${A:-0}" = "1" ]; then
    ok "ensure_trust_row is idempotent (still one row, one authority)"
  else
    err "ensure_trust_row duplicated the row (rows=$N authorities=$A)"; FAIL=1
  fi
  ensure_trust_row "$HOMEDIR" "node2.example.ts.net" >/dev/null 2>&1
  if grep -qF -- '- node2.example.ts.net' "$HOMEDIR/profiles/web/cordis.patch.yml"; then
    ok "ensure_trust_row adds a second authority to the existing row"
  else
    err "ensure_trust_row failed to add a second authority"; FAIL=1
  fi
  BEFORE=$(grep -cE '^\s*- id:' "$HOMEDIR/profiles/web/cordis.patch.yml" 2>/dev/null)
  if [ "${BEFORE:-0}" = "1" ]; then
    ok "no unrelated rows were touched"
  else
    err "row count changed unexpectedly ($BEFORE)"; FAIL=1
  fi
  rm -rf "$TMPT"

  if [ "$FAIL" = "0" ]; then ok "self-test passed"; exit 0; else err "self-test FAILED"; exit 1; fi
fi

# ---------------------------------------------------------------- diagnose

if [ "$DIAGNOSE" = "1" ]; then
  step "Diagnose (read-only - changes nothing on this host)"

  ACTIVE="no systemd"
  command -v systemctl >/dev/null 2>&1 && ACTIVE="$(systemctl is-active "$SERVICE_NAME" 2>&1 || true)"
  echo "  unit $SERVICE_NAME : $ACTIVE"
  UNIT_FILE="/etc/systemd/system/$SERVICE_NAME.service"
  UNIT_HOME=""; UNIT_PORT=""
  if [ -f "$UNIT_FILE" ]; then
    echo "  unit file         : $UNIT_FILE"
    grep -E '^(User|Environment|ExecStart)=' "$UNIT_FILE" 2>/dev/null | sed 's/^/    /' || true
    UNIT_HOME="$(grep -m1 '^Environment=DSH_HOME=' "$UNIT_FILE" | cut -d= -f3- || true)"
    UNIT_PORT="$(grep -m1 '^ExecStart=' "$UNIT_FILE" | grep -o -- '--port [0-9]*' | awk '{print $2}' || true)"
  fi
  PROC_PORT="$(pgrep -af 'bin\.js web' 2>/dev/null | grep -o -- '--port [0-9]*' | head -n1 | awk '{print $2}' || true)"
  pgrep -af 'bin\.js web' 2>/dev/null | head -n3 | sed 's/^/  proc: /' || true
  PORT="${UNIT_PORT:-${PROC_PORT:-3080}}"

  DNS=""
  command -v tailscale >/dev/null 2>&1 && DNS="$(tailnet_dns_name || true)"
  echo "  tailnet dns       : ${DNS:-<not in a tailnet>}"
  command -v tailscale >/dev/null 2>&1 && { tailscale serve status 2>/dev/null | sed 's/^/  serve: /' || true; }

  echo "  -- trust rows found --"
  for h in /root /home/* "$HOME"; do
    [ -d "$h" ] || continue
    f="$h/.dsh/profiles/web/cordis.patch.yml"
    if [ -f "$f" ]; then
      echo "  $f -> $(grep -c 'id: connection' "$f" 2>/dev/null) connection row(s)"
    fi
  done

  echo "  -- probes --"
  echo "  loopback /          : $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$PORT/" 2>/dev/null || echo err)"
  FENCE="none"
  if [ -n "$DNS" ]; then
    FENCE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 12 "https://$DNS/api/session.list" 2>/dev/null || echo err)"
    echo "  tailnet /api, no cookie : $FENCE   (401 = fence trusts us; 403 = fence rejects = blank page)"
  fi

  TOKEN=""
  command -v journalctl >/dev/null 2>&1 && TOKEN="$(journalctl -u "$SERVICE_NAME" --no-pager -n 300 2>/dev/null | grep -o 'token=[A-Za-z0-9_.-]*' | tail -n1 | cut -d= -f2 || true)"
  [ -z "$TOKEN" ] && command -v systemctl >/dev/null 2>&1 && TOKEN="$(systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | grep -o 'token=[A-Za-z0-9_.-]*' | tail -n1 | cut -d= -f2 || true)"
  [ -z "$TOKEN" ] && [ -f "$SCRIPT_DIR/dsh-web-token.txt" ] && TOKEN="$(head -n1 "$SCRIPT_DIR/dsh-web-token.txt" 2>/dev/null || true)"
  echo "  launch token       : ${TOKEN:+found}"

  step "Verdict"
  if [ "$FENCE" = "403" ]; then
    err "  /api answers 403 over the tailnet entry: the browser-trust fence rejects this Host."
    echo "     THIS is the blank page: the page HTML loads, then every API call comes back 403."
    if [ -n "$UNIT_HOME" ]; then
      if grep -q 'id: connection' "$UNIT_HOME/profiles/web/cordis.patch.yml" 2>/dev/null; then
        warn "  the unit reads $UNIT_HOME and it HAS a connection row - check what it lists:"
        grep -A4 'id: connection' "$UNIT_HOME/profiles/web/cordis.patch.yml" | sed 's/^/       /'
        echo "     it must list the name you open in the browser: $DNS"
      else
        err "  the unit reads $UNIT_HOME but that home has NO connection row."
        echo "     FIX (self-healing, writes the row + restarts):"
        echo "       sudo $0 --install-service"
      fi
    else
      echo "     FIX (self-healing, writes the row + restarts):"
      echo "       sudo $0 --install-service"
    fi
  elif [ "$FENCE" = "401" ]; then
    ok "  fence is fine (401 = authentication wanted, that is intended dsh 0.2.x behaviour)."
    if [ -n "$TOKEN" ]; then
      echo "     first visit must carry the token (30-day cookie after that):"
      echo "       https://$DNS/?token=$TOKEN"
    else
      echo "     get the token with: journalctl -u $SERVICE_NAME --no-pager | grep 'dsh web:'"
    fi
  else
    warn "  no verdict: /api answered '$FENCE'. See the probes above."
  fi

  step "Requirements check"
  if command -v tailscale >/dev/null 2>&1; then
    # an entry without "(tailnet only)" means it is published via Funnel (public)
    if tailscale serve status 2>/dev/null | grep -E '^https?://' | grep -qv '(tailnet only)'; then
      err "  tailscale funnel is ENABLED - the GUI is published on the public internet"
      echo "     (if unintended: tailscale funnel reset)"
    else
      ok "  tailscale serve is tailnet-only (no public funnel)"
    fi
  fi
  CREDS=""
  for h in /root /home/* "$HOME"; do
    [ -f "$h/.dsh/.credentials.yaml" ] && CREDS="$h/.dsh/.credentials.yaml"
    [ -f "$h/.dsh/profiles/web/cordis.patch.yml" ] && grep -qE '(llm-pi-ai|agent-default-model|providers:)' "$h/.dsh/profiles/web/cordis.patch.yml" 2>/dev/null && CREDS="configured-in $h/.dsh"
  done
  if [ -n "$CREDS" ]; then
    ok "  model config/credentials found ($CREDS)"
  else
    warn "  NO model configured on this host - open Settings and add a provider (baseURL/model/API key),"
    echo "     or copy .credentials.yaml + the llm-pi-ai / agent-default-model rows from a working ~/.dsh"
  fi
  echo "  browser : requires Firefox >=121 / Chrome >=119 / Safari >=17.4 (0.2.x uses"
  echo "            Promise.withResolvers + class static blocks; older browsers render blank)"
  exit 0
fi

# ---------------------------------------------------------------- 1. environment

step "Environment check"

[ "$(uname -s)" = "Linux" ] || die "this script targets Linux (found $(uname -s)); use start.ps1 on Windows"
OS_PRETTY="$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}") || printf 'Linux')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) NODE_ARCH="x64" ;;
  aarch64|arm64) NODE_ARCH="arm64" ;;
  *) NODE_ARCH="" ;;
esac
ok "$OS_PRETTY ($ARCH_RAW)"
[ "$(id -u)" = "0" ] && ok "running as root" || ok "running unprivileged (private Node is supported; systemd management still needs root)"

if [ "$DO_CLONE" = "1" ] && [ ! -f "$SCRIPT_DIR/package.json" ]; then
  step "Cloning the launcher repository"
  command -v git >/dev/null 2>&1 || die "git is required for --clone"
  git clone --depth 1 https://github.com/nene112/dsh_auto.git "$SCRIPT_DIR/dsh_auto"
  SCRIPT_DIR="$SCRIPT_DIR/dsh_auto"
  ok "cloned into $SCRIPT_DIR"
fi

[ -f "$SCRIPT_DIR/package.json" ] || die "no package.json in $SCRIPT_DIR - run this from the launcher checkout (or pass --clone)"
cd "$SCRIPT_DIR"

if [ -x "$NODE_PREFIX/bin/node" ]; then
  PATH="$NODE_PREFIX/bin:$PATH"; export PATH
  hash -r
fi

if node_usable && [ "$FORCE_NODE" = "0" ]; then
  ok "Node.js $(node -v) (within ^22.19 || >=24)"
else
  if command -v node >/dev/null 2>&1; then
    warn "Node.js $(node -v) is outside the supported range (^22.19.0 || >=24.0.0)"
  else
    warn "Node.js not found"
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "would install a private Node.js v$NODE_MAJOR_TARGET runtime in $NODE_PREFIX (skipped: --check-only)"
  else
    [ -n "$NODE_ARCH" ] || die "no official Node build for $ARCH_RAW"
    step "Installing Node.js v$NODE_MAJOR_TARGET into the private prefix $NODE_PREFIX"
    REL_BASE="latest-v${NODE_MAJOR_TARGET}.x"
    TMP="$(mktemp -d)"
    USED_BASE="$(fetch_node_file "$REL_BASE/SHASUMS256.txt" "$TMP/SHASUMS256.txt")" \
      || die "could not download Node.js checksums from the configured mirrors"
    FILE="$(grep -o "node-v[0-9.]*-linux-${NODE_ARCH}\.tar\.xz" "$TMP/SHASUMS256.txt" | head -n1)"
    [ -n "$FILE" ] || die "could not find a linux-${NODE_ARCH} tarball in SHASUMS256.txt"
    if ! fetch "$USED_BASE/$REL_BASE/$FILE" "$TMP/$FILE" 2>/dev/null; then
      warn "archive download failed from the checksum mirror; trying configured fallbacks"
      fetch_node_file "$REL_BASE/$FILE" "$TMP/$FILE" >/dev/null \
        || die "could not download $FILE from the configured mirrors"
    fi
    ( cd "$TMP" && grep " $FILE\$" SHASUMS256.txt | sha256sum -c - ) || die "checksum mismatch for $FILE"
    clear_owned_node_prefix
    mkdir -p "$NODE_PREFIX"
    tar -xJf "$TMP/$FILE" -C "$NODE_PREFIX" --strip-components=1 --no-same-owner
    : > "$NODE_PREFIX/.dsh-auto-node-runtime"
    rm -rf "$TMP"
    PATH="$NODE_PREFIX/bin:$PATH"; export PATH
    hash -r
    node_usable || die "Node install did not produce a usable node in $NODE_PREFIX/bin"
    ok "Node.js $(node -v) installed in $NODE_PREFIX (no global node/npm was replaced)"
  fi
fi

command -v npm >/dev/null 2>&1 && ok "npm $(npm -v 2>/dev/null || echo '?')" || warn "npm not on PATH"
NPM_REGISTRY="$(select_npm_registry)"
npm_config_registry="$NPM_REGISTRY"; export npm_config_registry
ok "npm registry $NPM_REGISTRY (current run only)"

unset PATCH_ENGINE || true
case "$(patch_engine)" in
  python3) ok "patch engine: python3" ;;
  perl)    ok "patch engine: perl" ;;
  node)    ok "patch engine: node" ;;
  *)
    if [ "$CHECK_ONLY" = "1" ]; then warn "no patch engine yet; the private Node install would provide one"
    else die "no working patch engine after Node.js setup"; fi ;;
esac

TS_DNS=""
if [ "$USE_TAILSCALE" = "1" ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "tailscale not installed - the GUI will be loopback-only"
    USE_TAILSCALE=0
  elif ! TS_DNS="$(tailnet_dns_name)"; then
    warn "tailscale is installed but not reporting a node (not logged in?) - loopback only"
    USE_TAILSCALE=0
  else
    ok "Tailscale node $TS_DNS"
  fi
else
  ok "Tailscale disabled by default (pass --tailscale to enable it)"
fi

if [ "$INSTALL_SERVICE" = "1" ] || [ "$UNINSTALL_SERVICE" = "1" ]; then
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found: this host has no systemd"
  [ "$(id -u)" = "0" ] || die "service management needs root - re-run with sudo"
fi

# ---------------------------------------------------------------- preflight
# Everything below this point that is not inside $SCRIPT_DIR is shared with the
# rest of the host, so check for conflicts first and refuse instead of clobbering.

step "Preflight: conflicts with what is already on this host"

PORT_OWNER=""
if command -v ss >/dev/null 2>&1; then
  PORT_OWNER="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$" {print $4" "$6; exit}')"
elif command -v netstat >/dev/null 2>&1; then
  PORT_OWNER="$(netstat -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$" {print $4" "$7; exit}')"
elif command -v timeout >/dev/null 2>&1 && timeout 1 bash -c "</dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  PORT_OWNER="127.0.0.1:$PORT (connect probe - install iproute2 for a precise owner)"
fi
SERVICE_ACTIVE=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then SERVICE_ACTIVE=1; fi
if [ "$SERVICE_ACTIVE" = "1" ]; then
  if [ "$INSTALL_SERVICE" = "1" ] || [ "$UNINSTALL_SERVICE" = "1" ]; then
    ok "port $PORT is held by our own unit ($SERVICE_NAME) - it will be restarted"
  else
    # Foreground mode cannot replace a running unit; saying "will be restarted"
    # would be a lie, and node would then die with EADDRINUSE on $PORT.
    err "the $SERVICE_NAME unit is already running and holds 127.0.0.1:$PORT."
    echo "  stop it first, or use the systemd flow instead:"
    echo "    systemctl stop $SERVICE_NAME        # then run this script again"
    echo "    sudo $0 --install-service           # or let systemd replace it"
    exit 1
  fi
elif [ -n "$PORT_OWNER" ]; then
  if [ "$FORCE" = "1" ]; then
    warn "port $PORT is in use ($PORT_OWNER) - continuing because of --force"
  elif [ "$CHECK_ONLY" = "1" ]; then
    warn "port $PORT would be refused: already in use ($PORT_OWNER); pick --port N"
  else
    die "port $PORT is already in use ($PORT_OWNER). Pick another with --port N - this script never kills anything."
  fi
else
  ok "port $PORT is free"
fi

if [ "$USE_TAILSCALE" = "1" ]; then
  SERVE_CONFLICT="$(tailscale serve status 2>/dev/null | awk -v host="$TS_DNS" -v tp="$TS_PORT" -v want="http://127.0.0.1:$PORT" "$SERVE_CONFLICT_AWK")"
  if [ -n "$SERVE_CONFLICT" ]; then
    if [ "$FORCE" = "1" ]; then
      warn "tailscale https :$TS_PORT already serves something else - replacing because of --force: $SERVE_CONFLICT"
    elif [ "$CHECK_ONLY" = "1" ]; then
      warn "tailscale https :$TS_PORT already serves something else: $SERVE_CONFLICT (would use --ts-port N)"
    else
      die "tailscale https :$TS_PORT already serves something else: $SERVE_CONFLICT
 Use --ts-port N to pick another port, or --force to replace that mapping on purpose."
    fi
  else
    ok "tailscale https :$TS_PORT is free or already maps to us"
  fi
fi

UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
UNIT_OURS=0
if [ -f "$UNIT_PATH" ] && grep -q 'Written by dsh_auto' "$UNIT_PATH" 2>/dev/null; then UNIT_OURS=1; fi
if [ "$UNIT_OURS" = "1" ]; then
  ok "systemd unit $SERVICE_NAME is ours (rewritten by this script)"
elif [ -f "$UNIT_PATH" ]; then
  if [ "$FORCE" = "1" ]; then
    warn "$UNIT_PATH exists and this script did not write it - overwriting because of --force"
  elif [ "$CHECK_ONLY" = "1" ]; then
    warn "$UNIT_PATH exists and this script did not write it (would refuse; use --service-name other)"
  else
    die "$UNIT_PATH already exists and was not written by this script - refusing to overwrite it.
 Use --service-name <other> or --force if you really mean to replace it."
  fi
else
  ok "no systemd unit named $SERVICE_NAME"
fi

if [ "$CHECK_ONLY" = "1" ]; then
  step "Check-only run finished (nothing was installed, patched or started)"
  exit 0
fi

# ---------------------------------------------------------------- 2. dependencies

step "Dependencies"

DSH_BIN="node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -f "$DSH_BIN" ] || ! npm ls @deepseek-ai/dsh --depth=0 >/dev/null 2>&1; then
  if [ -f package-lock.json ]; then
    npm ci --no-fund --no-audit || { warn "npm ci failed; falling back to npm install"; npm install --no-fund --no-audit; }
  else
    npm install --no-fund --no-audit
  fi
fi
[ -f "$DSH_BIN" ] || die "install finished but $DSH_BIN is missing"
ok "@deepseek-ai/dsh $(node -p "require('./node_modules/@deepseek-ai/dsh/package.json').version")"

# npm 11 gates dependency install scripts; node-pty and koffi are native, so a
# tree installed without those steps looks fine and fails later inside the UI.
if node -e "require('node-pty');require('koffi')" >/dev/null 2>&1; then
  ok "native modules load (node-pty, koffi)"
else
  warn "native modules do not load; approving install scripts and rebuilding"
  npm approve-scripts --all >/dev/null 2>&1 || true
  npm rebuild >/dev/null 2>&1 || warn "npm rebuild reported a problem"
  if node -e "require('node-pty');require('koffi')" >/dev/null 2>&1; then
    ok "native modules rebuilt"
  else
    warn "native modules still fail to load; terminal features may be unavailable"
  fi
fi

# ---------------------------------------------------------------- 3. LAN patches

step "LAN / Tailscale patches"
DSHROOT="node_modules/@deepseek-ai"

# Settings documents (the settings screen's actions) are gated on loopback.
# 0.2.x reads ctx.configForms.describe(); 0.1.x read ctx.settingsScope.describe().
if ! patch_literal "$DSHROOT/dsh-client-ui-settings-general/lib/client.js" \
  'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.configForms.describe()) : void 0;' \
  'const documentController = new SettingsDocumentStore(ctx, ctx.configForms.describe()); // LAN/Tailscale: enable settings document actions' \
  "LAN/Tailscale: enable settings document" "settings-general (0.2.x form)"; then
  patch_literal "$DSHROOT/dsh-client-ui-settings-general/lib/client.js" \
    'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe()) : void 0;' \
    'const documentController = new SettingsDocumentStore(ctx, ctx.settingsScope.describe()); // LAN/Tailscale: enable settings document actions' \
    "LAN/Tailscale: enable settings document" "settings-general (0.1.x form)" || true
fi

# Host-backed settings (models/credentials) used to fall back to memory off
# loopback; 0.2.x has no such gate left, so this only matches on 0.1.x.
patch_literal "$DSHROOT/dsh-client-ui-settings/lib/client.js" \
  'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";' \
  'const persistence = "host"; // LAN/Tailscale: enable Host-backed settings (models/credentials)' \
  "LAN/Tailscale: enable Host-backed settings" "ui-settings (0.1.x form)" \
  || warn "ui-settings: not needed on this version (expected on 0.2.x)"

# A native file dialog cannot appear on the machine serving the page.
DIRPICK="$DSHROOT/dsh-host-directory-picker-auto/lib/index.js"
if grep -qF -- 'return "browse"; // Tailscale/LAN' "$DIRPICK" 2>/dev/null; then
  ok "directory-picker: already patched (marker from an earlier start.sh)"
else
  patch_literal "$DIRPICK" \
    'if (facts.platform === "darwin" || facts.platform === "win32") return "native";' \
    'if (facts.platform === "darwin" || facts.platform === "win32") return "browse"; // LAN/Tailscale' \
    'return "browse"; // LAN/Tailscale' "directory-picker" || true
fi

warn "workspace-new-session: NOT applied - 0.2.x rewrote that logic, so verify the New Session button by hand"

# ---------------------------------------------------------------- 4. trust config

if [ "$INSTALL_SERVICE" = "1" ]; then
  # The unit runs as this user, so the trust row has to live in THAT user's dsh
  # home. Under sudo, $HOME is /root while SUDO_USER is someone else, and the
  # service would then read a different config and answer 403 over the tailnet.
  RUN_USER="${SERVICE_USER:-${SUDO_USER:-root}}"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  [ -n "$RUN_HOME" ] || RUN_HOME="/root"
fi

DSH_HOME_DIR="${DSH_HOME:-${RUN_HOME:-$HOME}/.dsh}"
PROFILE_PATCH="$DSH_HOME_DIR/profiles/web/cordis.patch.yml"

if [ "$USE_TAILSCALE" = "1" ]; then
  step "Trust config for the tailnet authority"
  ensure_trust_row "$DSH_HOME_DIR" "$TS_DNS"
fi

# ---------------------------------------------------------------- 5. tailnet entry

if [ "$USE_TAILSCALE" = "1" ]; then
  step "Tailnet entry: https://$TS_DNS:$TS_PORT/ -> http://127.0.0.1:$PORT (tailnet only)"
  tailscale serve --bg --https="$TS_PORT" --yes "http://127.0.0.1:$PORT" || warn "tailscale serve exited $?"
  tailscale serve status 2>/dev/null | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------- 6. start

TRUSTED_ARGS=()
TS_AUTHORITY="$TS_DNS"                    # for URLs: :443 is implied, other ports explicit
if [ "$USE_TAILSCALE" = "1" ]; then
  # measured behaviour: a port-less trusted-host entry matches every port, so the
  # bare DNS name is the right thing to declare here (it also covers :443).
  TRUSTED_ARGS=(--trusted-host "$TS_DNS")
  if [ "$TS_PORT" != "443" ]; then TS_AUTHORITY="$TS_DNS:$TS_PORT"; fi
fi

if [ "$UNINSTALL_SERVICE" = "1" ]; then
  step "Removing the systemd unit"
  if [ -f "$UNIT_PATH" ] && [ "$UNIT_OURS" = "0" ] && [ "$FORCE" != "1" ]; then
    die "$UNIT_PATH was not written by this script - refusing to remove it (use --force if you mean it)"
  fi
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  ok "unit removed (the tailscale entry is untouched: 'tailscale serve --https=$TS_PORT off' removes it)"
  exit 0
fi

if [ "$INSTALL_SERVICE" = "1" ]; then
  step "Installing the systemd unit ($SERVICE_NAME)"
  RUN_USER="${RUN_USER:-${SERVICE_USER:-${SUDO_USER:-root}}}"
  RUN_HOME="${RUN_HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)}"
  [ -n "$RUN_HOME" ] || RUN_HOME="/root"
  NODE_EXE="$(command -v node)"
  UNIT_DESCRIPTION="DeepSeek Harness web UI"
  UNIT_AFTER="network-online.target"
  UNIT_WANTS="network-online.target"
  if [ "$USE_TAILSCALE" = "1" ]; then
    UNIT_DESCRIPTION="$UNIT_DESCRIPTION (Tailscale tailnet entry)"
    UNIT_AFTER="$UNIT_AFTER tailscaled.service"
    UNIT_WANTS="$UNIT_WANTS tailscaled.service"
  fi
  cat > "$UNIT_PATH" <<EOF
# Written by dsh_auto/start.sh - remove with: start.sh --uninstall-service
[Unit]
Description=$UNIT_DESCRIPTION
After=$UNIT_AFTER
Wants=$UNIT_WANTS

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$SCRIPT_DIR
Environment=DSH_HOME=$RUN_HOME/.dsh
Environment=HOME=$RUN_HOME
ExecStart=$NODE_EXE $SCRIPT_DIR/$DSH_BIN web --no-open --port $PORT ${TRUSTED_ARGS[*]:-}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  sleep 3
  ok "unit installed and started as user $RUN_USER"
else
  step "Starting dsh web on 127.0.0.1:$PORT (foreground; Ctrl+C stops it)"
  echo "    node $DSH_BIN web --no-open --port $PORT ${TRUSTED_ARGS[*]:-}"
  echo "    footprint: this directory + node_modules + $PROFILE_PATCH (nothing else)"
  echo
  # the ${arr[@]+...} form keeps 'set -u' happy on bash 4.2 (RHEL 7) when empty
  exec node "$DSH_BIN" web --no-open --port "$PORT" ${TRUSTED_ARGS[@]+"${TRUSTED_ARGS[@]}"}
fi

# ---------------------------------------------------------------- 7. verify

step "Verify"
PROBE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/" || echo 000)"
case "$PROBE" in
  401) ok "loopback answers 401 - dsh 0.2.x authentication is on (expected)" ;;
  200) ok "loopback answers 200 - dsh 0.1.x style, no token needed" ;;
  *)   warn "loopback answered '$PROBE' - check: journalctl -u $SERVICE_NAME -n 50" ;;
esac

TOKEN=""
for _ in $(seq 1 20); do
  if command -v journalctl >/dev/null 2>&1; then
    TOKEN="$(journalctl -u "$SERVICE_NAME" --no-pager -n 200 2>/dev/null | grep -o 'token=[A-Za-z0-9_.-]*' | tail -n1 | cut -d= -f2 || true)"
  fi
  if [ -z "$TOKEN" ] && command -v systemctl >/dev/null 2>&1; then
    TOKEN="$(systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | grep -o 'token=[A-Za-z0-9_.-]*' | tail -n1 | cut -d= -f2 || true)"
  fi
  [ -n "$TOKEN" ] && break
  sleep 1
done
if [ -n "$TOKEN" ]; then
  printf '%s\n' "$TOKEN" > "$SCRIPT_DIR/dsh-web-token.txt"
  chmod 600 "$SCRIPT_DIR/dsh-web-token.txt"
  ok "launch token saved to $SCRIPT_DIR/dsh-web-token.txt (chmod 600; regenerates on every start)"
fi

if [ "$USE_TAILSCALE" = "1" ]; then
  # The decisive blank-page probe. The page itself loads even when untrusted, so
  # ask /api instead: 401 = the fence trusts us and wants the token (right);
  # 403 = the fence rejects us -> the page loads and renders BLANK.
  FENCE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$TS_AUTHORITY/api/session.list" || echo 000)"
  case "$FENCE" in
    401)
      ok "tailnet /api answers 401 without a cookie - $TS_AUTHORITY is trusted, auth is on"
      ;;
    403)
      err "tailnet /api answers 403: the trust fence rejects $TS_AUTHORITY - THIS is what renders as a blank page"
      if [ "$INSTALL_SERVICE" = "1" ]; then
        step "Self-heal: rewrite the connection row into the home the unit uses and restart"
        ensure_trust_row "$RUN_HOME/.dsh" "$TS_DNS" || true
        systemctl restart "$SERVICE_NAME"
        sleep 4
        FENCE2="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$TS_AUTHORITY/api/session.list" || echo 000)"
        if [ "$FENCE2" = "401" ]; then
          ok "healed: /api now answers 401 (wants the token) - the page will render"
        else
          err "still $FENCE2 after the heal - the unit may read another DSH_HOME; run: $0 --diagnose"
        fi
      else
        err "add the connection row to $PROFILE_PATCH and restart; or re-run with --install-service (self-heals)"
      fi
      ;;
    *)
      warn "tailnet /api answered '$FENCE' (expected 401 without a cookie)"
      ;;
  esac

  if [ -n "$TOKEN" ]; then
    JAR="$(mktemp)"
    FIRST="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -c "$JAR" "https://$TS_AUTHORITY/?token=$TOKEN" || echo 000)"
    AFTER="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -b "$JAR" "https://$TS_AUTHORITY/" || echo 000)"
    WS="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -b "$JAR" \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://$TS_AUTHORITY/api/remote.mux" || echo 000)"
    rm -f "$JAR"
    ok "token exchange -> $FIRST (303 expected), page with cookie -> $AFTER, WebSocket mux -> $WS (101 expected)"
  else
    warn "no token found yet; get it with: journalctl -u $SERVICE_NAME --no-pager | grep 'dsh web:'"
  fi
fi

# ----------------------------------------------------------------
# Requirements the script cannot satisfy by itself - report them, loudly.

MODEL_NOTE=""
if [ ! -f "$DSH_HOME_DIR/.credentials.yaml" ] \
   && ! grep -qE '(llm-pi-ai|agent-default-model|providers:)' "$PROFILE_PATCH" 2>/dev/null; then
  MODEL_NOTE="
   no model configured yet (empty $DSH_HOME_DIR). Open Settings and add your
   provider (baseURL, model id, API key) - or copy .credentials.yaml and the
   llm-pi-ai / agent-default-model rows from a working machine's ~/.dsh here."
fi

ACCESS_NOTE=""
if [ "$USE_TAILSCALE" = "0" ]; then
  ACCESS_NOTE="
   loopback only (no tailnet entry), so only this host can reach the GUI.
   Remote access over plain http:// would fail (crypto.randomUUID needs a
   secure context) - install Tailscale and drop --no-tailscale, or accept
   loopback-only access."
fi

FUNNEL_ON=0
if command -v tailscale >/dev/null 2>&1; then
  # an entry without "(tailnet only)" is public (Funnel enabled)
  if tailscale serve status 2>/dev/null | grep -E '^https?://' | grep -qv '(tailnet only)'; then FUNNEL_ON=1; fi
fi

cat <<EOF

=====================================================================
 dsh is up on 127.0.0.1:$PORT
EOF
if [ "$USE_TAILSCALE" = "1" ] && [ -n "$TOKEN" ]; then
  cat <<EOF
 FIRST visit from each device must carry the token (30-day cookie after that):
   https://$TS_AUTHORITY/?token=$TOKEN
EOF
fi
cat <<EOF

 REQUIREMENTS & GOTCHAS (the script cannot do these for you)
 - browser : Firefox >=121 / Chrome >=119 / Safari >=17.4. 0.2.x uses
   Promise.withResolvers + class static blocks; older browsers render BLANK
   (console: "Promise.withResolvers is not a function" / "expected property
   name, got '{'").
EOF
[ -n "$MODEL_NOTE" ]  && printf '%s\n' " - model  :$MODEL_NOTE"
[ -n "$ACCESS_NOTE" ] && printf '%s\n' " - access :$ACCESS_NOTE"
if [ "$FUNNEL_ON" = "1" ]; then
  cat <<EOF
 - SECURITY: 'tailscale funnel' is ENABLED - this GUI is published on the public
   internet. If that was not intended:  tailscale funnel reset
EOF
fi
cat <<EOF

 service    : systemctl status|restart|stop $SERVICE_NAME
 logs/token : journalctl -u $SERVICE_NAME -f      (grep 'dsh web:' for the token)
 tailnet off: tailscale serve --https=$TS_PORT off
 notes      : the token is regenerated on every start, existing cookies survive;
              keep the 'connection' row in $PROFILE_PATCH or /api answers 403.

 System footprint (nothing else on this host was touched):
   $SCRIPT_DIR
   $SCRIPT_DIR/node_modules
   $PROFILE_PATCH
   $UNIT_PATH
   tailscale serve --https=$TS_PORT -> http://127.0.0.1:$PORT
   no global npm package, no firewall rule, no other service or Node install
=====================================================================
EOF
