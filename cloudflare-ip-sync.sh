#!/bin/bash
set -euo pipefail

# ----------------------------
# Load shared env + library
# ----------------------------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${BASE_DIR}/lib"

[[ -f /etc/default/allowlist-sync ]] && source /etc/default/allowlist-sync
source "${LIB_DIR}/common.sh"

# ----------------------------
# Defaults / config
# ----------------------------
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
TRAEFIK_EXEC_USER="${TRAEFIK_EXEC_USER:-}"  # empty = container default user
TRAEFIK_FILES_DEFAULT="/etc/traefik.d/http.internalonly.yaml /etc/traefik.d/http.crowdsec.yaml"
TARGET_FILES="${TARGET_FILES:-${TRAEFIK_FILES:-$TRAEFIK_FILES_DEFAULT}}"

# Optional restart (off by default; directory expected to be watched)
TRAEFIK_RESTART="${TRAEFIK_RESTART:-0}"

CF_V4_URL="${CF_V4_URL:-https://www.cloudflare.com/ips-v4/}"
CF_V6_URL="${CF_V6_URL:-https://www.cloudflare.com/ips-v6/}"

CTX="cloudflare trusted IPs"

on_error() {
  local ec=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local cmd="${BASH_COMMAND:-unknown}"
  if declare -F discord_notify_error >/dev/null 2>&1; then
    discord_notify_error "cloudflare" "$CTX" "exit=${ec} line=${line} cmd=${cmd}"
  fi
  exit "$ec"
}
trap on_error ERR

require_bins "$PYTHON3" "$CURL" "$AWK"
require_bins /usr/bin/docker

docker_exec_i() {
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
  local path="$1"
  local tmp="${path}.tmp.$$"
  docker_exec_i sh -c "cat > \"${tmp}\"" <<<"$2"
  docker_exec_i sh -c "mv -f \"${tmp}\" \"${path}\""
}

fetch_list() {
  local url="$1"
  "$CURL" -fsS "$url" | "$AWK" 'NF{print $1}'
}

mapfile -t CF_V4 < <(fetch_list "$CF_V4_URL")
mapfile -t CF_V6 < <(fetch_list "$CF_V6_URL")

((${#CF_V4[@]} > 0)) || die "Failed to fetch Cloudflare IPv4 list from ${CF_V4_URL}"
((${#CF_V6[@]} > 0)) || die "Failed to fetch Cloudflare IPv6 list from ${CF_V6_URL}"

V4_LINES="$(printf '%s\n' "${CF_V4[@]}")"
V6_LINES="$(printf '%s\n' "${CF_V6[@]}")"

changed_any=0

for f in $TARGET_FILES; do
  old="$(container_read_file "$f" || true)"
  [[ -n "$old" ]] || continue

  new="$("$PYTHON3" -c '
import re, sys

src = sys.argv[1]
v4 = [x.strip() for x in sys.argv[2].splitlines() if x.strip()]
v6 = [x.strip() for x in sys.argv[3].splitlines() if x.strip()]

def replace_block(text, name, items):
    # Markers:
    #   # BEGIN managed cloudflare ipv4
    #   ...
    #   # END managed cloudflare ipv4
    begin = re.escape(f"# BEGIN managed cloudflare {name}")
    end   = re.escape(f"# END managed cloudflare {name}")
    pat = re.compile(rf"(?ms)^([ \t]*){begin}[^\n]*\n(.*?)^([ \t]*){end}[^\n]*\n?")
    ms = list(pat.finditer(text))
    if not ms:
        return text, False

def render(indent, old_block_body):
    m_dash = re.search(r"(?m)^([ \t]*)-\s+", old_block_body)
    dash_indent = m_dash.group(1) if m_dash else indent

    out = [f"{indent}# BEGIN managed cloudflare {name}\n"]
    for it in items:
        out.append(f"{dash_indent}- {it}\n")
    out.append(f"{indent}# END managed cloudflare {name}\n")
    return "".join(out)

    out = []
    last = 0
    for m in ms:
        out.append(text[last:m.start()])
        out.append(render(m.group(1), m.group(2)))
        last = m.end()
    out.append(text[last:])
    return "".join(out), True

t1, c1 = replace_block(src, "ipv4", v4)
t2, c2 = replace_block(t1, "ipv6", v6)
print(t2, end="")
' "$old" "$V4_LINES" "$V6_LINES")"

  if [[ "$new" != "$old" ]]; then
    container_write_file_atomic "$f" "$new"
    log "Updated Cloudflare managed blocks in container file: $f"
    changed_any=1
  fi
done

if (( changed_any == 1 )); then
  discord_notify_change "add" "cloudflare" "$CTX" "refreshed from Cloudflare lists" "${CF_V4[@]}" "${CF_V6[@]}"

  if [[ "$TRAEFIK_RESTART" == "1" ]]; then
    log "Restarting Traefik container (optional): $TRAEFIK_CONTAINER"
    docker restart "$TRAEFIK_CONTAINER" >/dev/null
  fi
else
  log "No Cloudflare managed markers found/changed in configured container files"
fi
