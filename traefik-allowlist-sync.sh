#!/bin/bash
set -euo pipefail

# ----------------------------
# Load shared env + library
# ----------------------------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${BASE_DIR}/lib"

# Optional shared env file for all scripts
[[ -f /etc/default/allowlist-sync ]] && source /etc/default/allowlist-sync

# Shared library
source "${LIB_DIR}/common.sh"

# ----------------------------
# Defaults / config
# ----------------------------
IPV6_MODE="host"       # host | prefix
IPV6_PREFIXLEN=56

TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
TRAEFIK_EXEC_USER="${TRAEFIK_EXEC_USER:-}"  # empty = container default user
TRAEFIK_FILES_DEFAULT="/etc/traefik.d/http.internalonly.yaml /etc/traefik.d/http.crowdsec.yaml"
TRAEFIK_FILES="${TRAEFIK_FILES:-$TRAEFIK_FILES_DEFAULT}"

# Optional restart (off by default; directory expected to be watched)
TRAEFIK_RESTART="${TRAEFIK_RESTART:-0}"

usage() {
  cat <<EOF
Usage: $0 [--ipv6-prefix|--ipv6-host] [--ipv6-prefixlen N] <domain>

Edits Traefik YAML files INSIDE the Traefik container, updating all occurrences of:

  # BEGIN managed: <domain>
  ...
  # END managed: <domain>

Environment (usually from /etc/default/allowlist-sync):
  TRAEFIK_CONTAINER="traefik"
  TRAEFIK_FILES="/etc/traefik.d/http.internalonly.yaml /etc/traefik.d/http.crowdsec.yaml"
  TRAEFIK_EXEC_USER=""        # optional; docker exec -u <user>
  TRAEFIK_RESTART=0|1         # optional; docker restart traefik

Examples:
  $0 --ipv6-prefix --ipv6-prefixlen 56 host.domain.tld
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
[[ -n "$DOMAIN" ]] || { usage; exit 1; }

CTX="traefik managed-block: ${DOMAIN}"

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

docker_exec_i() {
  # docker_exec_i <cmd...> (stdin preserved)
  if [[ -n "$TRAEFIK_EXEC_USER" ]]; then
    docker exec -i -u "$TRAEFIK_EXEC_USER" "$TRAEFIK_CONTAINER" "$@"
  else
    docker exec -i "$TRAEFIK_CONTAINER" "$@"
  fi
}

container_read_file() {
  local path="$1"
  docker_exec_i sh -c "cat \"${path}\"" 2>/dev/null
}

container_write_file_atomic() {
  # Write new content to path inside container via temp file + mv
  local path="$1"
  local tmp="${path}.tmp.$$"

  # Write temp file
  docker_exec_i sh -c "cat > \"${tmp}\"" <<<"$2"
  # Move into place
  docker_exec_i sh -c "mv -f \"${tmp}\" \"${path}\""
}

render_domain_block() {
  # Produces newline-separated list items (no indentation; caller applies indentation)
  local -a items=("$@")
  printf '%s\n' "${items[@]}"
}

# ----------------------------
# Resolve DNS and compute desired items
# ----------------------------
A_IPS=(); AAAA_IPS=(); DESIRED=()
resolve_dns "$DOMAIN" A_IPS AAAA_IPS
build_desired_items A_IPS AAAA_IPS "$IPV6_MODE" "$IPV6_PREFIXLEN" DESIRED

BLOCK_LINES="$(render_domain_block "${DESIRED[@]}")"

changed_any=0

for f in $TRAEFIK_FILES; do
  # Read file inside container; if missing, skip silently
  old="$(container_read_file "$f" || true)"
  [[ -n "$old" ]] || continue

  new="$("$PYTHON3" -c '
import re, sys

domain = sys.argv[1]
items = [ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip()]
src = sys.argv[2]

begin = re.escape(f"# BEGIN managed: {domain}")
end   = re.escape(f"# END managed: {domain}")

# Match blocks including indentation from the BEGIN line.
pat = re.compile(rf"(?ms)^([ \t]*){begin}[^\n]*\n(.*?)^([ \t]*){end}[^\n]*\n?")

ms = list(pat.finditer(src))
if not ms:
    # No markers: return original unchanged
    print(src, end="")
    sys.exit(0)

def render(indent):
    dash_indent = indent + "    "
    out = [f"{indent}# BEGIN managed: {domain}\n"]
    for it in items:
        out.append(f"{dash_indent}- {it}\n")
    out.append(f"{indent}# END managed: {domain}\n")
    return "".join(out)

out = []
last = 0
for m in ms:
    out.append(src[last:m.start()])
    out.append(render(m.group(1)))
    last = m.end()
out.append(src[last:])
print("".join(out), end="")
' "$DOMAIN" "$old" <<<"$BLOCK_LINES")"

  if [[ "$new" != "$old" ]]; then
    container_write_file_atomic "$f" "$new"
    log "Updated domain managed blocks in container file: $f"
    changed_any=1
  fi
done

if (( changed_any == 1 )); then
  discord_notify_change "add" "$DOMAIN" "$CTX" "updated YAML managed block(s) (ipv6=${IPV6_MODE}/${IPV6_PREFIXLEN})" "${DESIRED[@]}"

  if [[ "$TRAEFIK_RESTART" == "1" ]]; then
    log "Restarting Traefik container (optional): $TRAEFIK_CONTAINER"
    docker restart "$TRAEFIK_CONTAINER" >/dev/null
  fi
else
  log "No domain managed markers found/changed for '${DOMAIN}' in configured container files"
fi
