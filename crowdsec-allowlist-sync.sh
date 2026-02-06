#!/bin/bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# Optional shared env file
[[ -f /etc/default/allowlist-sync ]] && source /etc/default/allowlist-sync
source "${LIB_DIR}/common.sh"

# CrowdSec / Docker config
CSCLI_CONTAINER="${CSCLI_CONTAINER:-crowdsec}"
CSCLI=(docker exec -i "$CSCLI_CONTAINER" cscli)

IPV6_MODE="host"
IPV6_PREFIXLEN=56

usage() {
  cat <<EOF
Usage: $0 [--ipv6-prefix|--ipv6-host] [--ipv6-prefixlen N] <domain> <allowlist_name>

Environment:
  CSCLI_CONTAINER=crowdsec
  (plus vars from /etc/default/allowlist-sync)

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipv6-prefix) IPV6_MODE="prefix"; shift ;;
    --ipv6-host) IPV6_MODE="host"; shift ;;
    --ipv6-prefixlen) IPV6_PREFIXLEN="${2:?Missing --ipv6-prefixlen value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

DOMAIN="${1:-}"
ALLOWLIST_NAME="${2:-}"
[[ -n "$DOMAIN" && -n "$ALLOWLIST_NAME" ]] || { usage; exit 1; }

CTX="crowdsec allowlist: ${ALLOWLIST_NAME}"

on_error() {
  local ec=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local cmd="${BASH_COMMAND:-unknown}"
  if declare -F discord_notify_error >/dev/null 2>&1; then
    discord_notify_error "$DOMAIN" "$CTX" "exit=${ec} line=${line} cmd=${cmd}"
  fi
  exit "$ec"
}
trap on_error ERR

require_bins "$PYTHON3" "$DIG" "$AWK" "$CURL"
require_bins /usr/bin/docker

# Resolve + compute desired items
A_IPS=(); AAAA_IPS=(); DESIRED=()
resolve_dns "$DOMAIN" A_IPS AAAA_IPS
build_desired_items A_IPS AAAA_IPS "$IPV6_MODE" "$IPV6_PREFIXLEN" DESIRED

# Ensure allowlist exists
if ! "${CSCLI[@]}" allowlist list -ojson | "$PYTHON3" -c '
import json,sys
data=json.load(sys.stdin)
name=sys.argv[1]
print("1" if any(x.get("name")==name for x in data) else "0")
' "$ALLOWLIST_NAME" | grep -q '^1$'; then
  log "Allowlist '$ALLOWLIST_NAME' not found, creating it..."
  "${CSCLI[@]}" allowlist create "$ALLOWLIST_NAME" -d "auto-synced from DNS"
  log "Adding initial items..."
  "${CSCLI[@]}" allowlist add "$ALLOWLIST_NAME" "${DESIRED[@]}"
  discord_notify_change "add" "$DOMAIN" "$CTX" "initial create (ipv6=${IPV6_MODE}/${IPV6_PREFIXLEN})" "${DESIRED[@]}"
  exit 0
fi

# Get existing items
mapfile -t EXISTING < <(
  "${CSCLI[@]}" allowlist list -ojson | "$PYTHON3" -c '
import json,sys
data=json.load(sys.stdin)
name=sys.argv[1]
for x in data:
  if x.get("name")==name:
    for it in (x.get("items") or []):
      v = it.get("value")
      if v: print(v)
' "$ALLOWLIST_NAME"
)

declare -A want=() have=()
for x in "${DESIRED[@]}"; do want["$x"]=1; done
for x in "${EXISTING[@]:-}"; do [[ -n "$x" ]] && have["$x"]=1; done

TO_ADD=(); TO_REMOVE=()
for x in "${!want[@]}"; do [[ -z "${have[$x]+x}" ]] && TO_ADD+=("$x"); done
for x in "${!have[@]}"; do [[ -z "${want[$x]+x}" ]] && TO_REMOVE+=("$x"); done

if (( ${#TO_ADD[@]} > 0 )); then
  log "Adding to $ALLOWLIST_NAME: ${TO_ADD[*]}"
  "${CSCLI[@]}" allowlist add "$ALLOWLIST_NAME" "${TO_ADD[@]}"
  discord_notify_change "add" "$DOMAIN" "$CTX" "ipv6=${IPV6_MODE}/${IPV6_PREFIXLEN}" "${TO_ADD[@]}"
fi

if (( ${#TO_REMOVE[@]} > 0 )); then
  log "Removing from $ALLOWLIST_NAME: ${TO_REMOVE[*]}"
  "${CSCLI[@]}" allowlist remove "$ALLOWLIST_NAME" "${TO_REMOVE[@]}"
  discord_notify_change "remove" "$DOMAIN" "$CTX" "ipv6=${IPV6_MODE}/${IPV6_PREFIXLEN}" "${TO_REMOVE[@]}"
fi
