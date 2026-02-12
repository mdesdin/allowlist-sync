#!/bin/bash
set -euo pipefail

# ----------------------------
# Configurable binaries
# ----------------------------
PYTHON3="${PYTHON3:-/usr/bin/python3}"
DIG="${DIG:-/usr/bin/dig}"
AWK="${AWK:-/usr/bin/awk}"
CURL="${CURL:-/usr/bin/curl}"

# ----------------------------
# Discord configuration
# ----------------------------
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-Allowlist Sync Bot}"
DISCORD_AVATAR_URL="${DISCORD_AVATAR_URL:-}"
DISCORD_NOTIFY_ON_ERROR="${DISCORD_NOTIFY_ON_ERROR:-1}"
DISCORD_DEBUG="${DISCORD_DEBUG:-0}"

# ----------------------------
# Logging helpers
# ----------------------------
log() { echo "[$(date -Is)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_bins() {
  local b
  for b in "$@"; do
    [[ -x "$b" ]] || die "Binary not found or not executable: $b"
  done
}

# ----------------------------
# IPv6 helpers
# ----------------------------
validate_prefixlen() {
  local plen="$1"
  [[ "$plen" =~ ^[0-9]+$ ]] || die "Invalid prefix length: $plen"
  (( plen >= 1 && plen <= 128 )) || die "Invalid prefix length: $plen (must be 1..128)"
}

ipv6_to_prefix() {
  local ip="$1"
  local plen="$2"
  "$PYTHON3" -c '
import ipaddress, sys
ip = sys.argv[1]
plen = int(sys.argv[2])
net = ipaddress.IPv6Network(f"{ip}/{plen}", strict=False)
print(f"{net.network_address}/{plen}")
' "$ip" "$plen"
}

# ----------------------------
# DNS resolve helpers
# ----------------------------
filter_valid_ip_or_cidr() {
  # Reads lines from stdin, prints only valid IPv4/IPv6 or CIDR blocks.
  "$PYTHON3" - <<'PY'
import sys, ipaddress
for line in sys.stdin:
    s = line.strip()
    if not s:
        continue
    # accept single IP or CIDR
    try:
        if "/" in s:
            ipaddress.ip_network(s, strict=False)
        else:
            ipaddress.ip_address(s)
        print(s)
    except Exception:
        pass
PY
}

resolve_dns() {
  # resolve_dns "domain" A_ARR AAAA_ARR
  local domain="$1"
  local -n _a="$2"
  local -n _aaaa="$3"

  # Make dig fail faster; adjust if you prefer
  local -a dig_opts=(+short +time=2 +tries=1)

  local out_a out_aaaa
  local rc_a rc_aaaa

  out_a="$("$DIG" "${dig_opts[@]}" A "$domain" 2>&1)" || rc_a=$?
  rc_a="${rc_a:-0}"

  out_aaaa="$("$DIG" "${dig_opts[@]}" AAAA "$domain" 2>&1)" || rc_aaaa=$?
  rc_aaaa="${rc_aaaa:-0}"

  # Filter strictly: keep only IP/CIDR lines
  mapfile -t _a < <(printf "%s\n" "$out_a" | filter_valid_ip_or_cidr)
  mapfile -t _aaaa < <(printf "%s\n" "$out_aaaa" | filter_valid_ip_or_cidr)

  # If dig failed and we got no valid records, treat as error and show useful context
  if (( ${#_a[@]} == 0 && ${#_aaaa[@]} == 0 )); then
    # Prefer the most informative output
    local diag="A(rc=$rc_a): $out_a"
    diag="$diag"$'\n'"AAAA(rc=$rc_aaaa): $out_aaaa"
    die "DNS lookup failed or returned no valid A/AAAA records for ${domain}. Output:\n${diag}"
  fi

  # If dig returned nonzero but we still got valid records, log a warning
  if (( rc_a != 0 || rc_aaaa != 0 )); then
    log "Warning: dig returned non-zero (A rc=$rc_a, AAAA rc=$rc_aaaa) but valid records were parsed for ${domain}"
  fi
}

build_desired_items() {
  # build_desired_items A_ARR AAAA_ARR ipv6_mode prefixlen OUT_ARR
  local -n _a="$1"
  local -n _aaaa="$2"
  local ipv6_mode="$3"     # host|prefix
  local prefixlen="$4"
  local -n _out="$5"

  local -A seen=()
  local ip prefix

  for ip in "${_a[@]}"; do
    seen["$ip"]=1
  done

  if (( ${#_aaaa[@]} > 0 )); then
    if [[ "$ipv6_mode" == "prefix" ]]; then
      validate_prefixlen "$prefixlen"
      for ip in "${_aaaa[@]}"; do
        prefix="$(ipv6_to_prefix "$ip" "$prefixlen")"
        seen["$prefix"]=1
      done
    else
      for ip in "${_aaaa[@]}"; do
        seen["$ip"]=1
      done
    fi
  fi

  _out=()
  for ip in "${!seen[@]}"; do
    _out+=("$ip")
  done

  ((${#_out[@]} > 0)) || die "No desired items computed"
}

# ----------------------------
# Discord notifications
# ----------------------------
discord_post_json() {
  local payload="$1"
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0

  if [[ "$DISCORD_DEBUG" == "1" ]]; then
    echo "[discord] payload: $payload"
    "$CURL" -v -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL"
  else
    "$CURL" -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

discord_notify_change() {
  # discord_notify_change action domain context_title extra_kv items...
  local action="$1"; shift
  local domain="$1"; shift
  local ctx="$1"; shift
  local extra="$1"; shift
  local -a items=("$@")

  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  [[ ${#items[@]} -gt 0 ]] || return 0

  local payload
  payload="$(
    {
      printf 'ITEMS\n'
      printf '%s\n' "${items[@]}"
    } | "$PYTHON3" -c '
import json, sys
from datetime import datetime, timezone

action = sys.argv[1]
domain = sys.argv[2]
ctx = sys.argv[3]
extra = sys.argv[4]

raw = sys.stdin.read().splitlines()
items = []
for line in raw:
    if line == "ITEMS": continue
    if line.strip(): items.append(line.strip())

v4 = [x for x in items if ":" not in x]
v6 = [x for x in items if ":" in x]

def block(lines, max_chars=900):
    if not lines:
        return "—"
    out = ""
    omitted = 0
    for x in lines:
        nxt = out + x + "\n"
        if len(nxt) > max_chars:
            omitted += 1
        else:
            out = nxt
    if omitted:
        out += f"... ({omitted} more omitted)"
    return f"```text\n{out.rstrip()}\n```"

if action == "add":
    color = 3066993; emoji = "🟢"
elif action == "remove":
    color = 15158332; emoji = "🔴"
else:
    color = 9807270; emoji = "ℹ️"

fields = [
  {"name": "Action", "value": action, "inline": True},
  {"name": "Domain", "value": domain, "inline": True},
  {"name": "Context", "value": ctx, "inline": False},
]
if extra:
  fields.append({"name": "Details", "value": extra, "inline": False})

fields.append({"name": "IPv4", "value": block(v4), "inline": False})
fields.append({"name": "IPv6 / Prefixes", "value": block(v6), "inline": False})

embed = {
  "title": f"{emoji} Allowlist sync update",
  "color": color,
  "fields": fields,
  "footer": {"text": "allowlist-sync"},
  "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
}

payload = {"embeds": [embed]}
print(json.dumps(payload))
' "$action" "$domain" "$ctx" "$extra"
  )"

  if [[ -n "$DISCORD_USERNAME" ]]; then
    payload="$("$PYTHON3" -c 'import json,sys; p=json.loads(sys.argv[1]); p["username"]=sys.argv[2]; print(json.dumps(p))' "$payload" "$DISCORD_USERNAME")"
  fi
  if [[ -n "$DISCORD_AVATAR_URL" ]]; then
    payload="$("$PYTHON3" -c 'import json,sys; p=json.loads(sys.argv[1]); p["avatar_url"]=sys.argv[2]; print(json.dumps(p))' "$payload" "$DISCORD_AVATAR_URL")"
  fi

  discord_post_json "$payload"
}

discord_notify_error() {
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  [[ "$DISCORD_NOTIFY_ON_ERROR" == "1" ]] || return 0

  local domain="${1:-unknown}"
  local ctx="${2:-unknown}"
  local msg="${3:-unknown}"

  local payload
  payload="$("$PYTHON3" -c '
import json, sys
from datetime import datetime, timezone
domain, ctx, msg = sys.argv[1:4]
embed = {
  "title": "🟠 Allowlist sync FAILED",
  "color": 15105570,
  "fields": [
    {"name": "Domain", "value": domain, "inline": True},
    {"name": "Context", "value": ctx, "inline": True},
    {"name": "Error", "value": f"```text\n{msg[:900]}\n```", "inline": False},
  ],
  "footer": {"text": "allowlist-sync"},
  "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
}
print(json.dumps({"embeds":[embed]}))
' "$domain" "$ctx" "$msg")"

  if [[ -n "$DISCORD_USERNAME" ]]; then
    payload="$("$PYTHON3" -c 'import json,sys; p=json.loads(sys.argv[1]); p["username"]=sys.argv[2]; print(json.dumps(p))' "$payload" "$DISCORD_USERNAME")"
  fi
  if [[ -n "$DISCORD_AVATAR_URL" ]]; then
    payload="$("$PYTHON3" -c 'import json,sys; p=json.loads(sys.argv[1]); p["avatar_url"]=sys.argv[2]; print(json.dumps(p))' "$payload" "$DISCORD_AVATAR_URL")"
  fi

  discord_post_json "$payload"
}

# ----------------------------
# Atomic file write (safe updates)
# ----------------------------
atomic_write() {
  # atomic_write /path/to/file "new content"
  local file="$1"
  local content="$2"

  local dir tmp owner group perm
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.tmp.$(basename "$file").XXXXXX")"

  # preserve metadata when possible
  if [[ -e "$file" ]]; then
    owner="$(stat -c '%u' "$file" 2>/dev/null || echo "")"
    group="$(stat -c '%g' "$file" 2>/dev/null || echo "")"
    perm="$(stat -c '%a' "$file" 2>/dev/null || echo "")"
  else
    owner=""; group=""; perm=""
  fi

  printf "%s" "$content" >"$tmp"

  if [[ -n "$perm" ]]; then chmod "$perm" "$tmp" || true; fi
  if [[ -n "$owner" && -n "$group" ]]; then chown "$owner:$group" "$tmp" || true; fi

  mv -f "$tmp" "$file"
}
