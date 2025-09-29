#!/usr/bin/env bash
set -euo pipefail

ZBX_SERVER="zabbix.domain.com.br"
ZBX_HOST="hostname.domain"
ZBX_KEY="webhook.alert"
LOGFILE="/var/log/webhook/webhook-listener.log"

log(){ echo "$(date) $*" >> "$LOGFILE"; }

# ---- read request line and headers (CRLF), detect Content-Length ----
clen=0
declare -A H

IFS= read -r request_line || true

while IFS= read -r line; do
  line="${line%$'\r'}"
  [ -z "$line" ] && break
  if [[ "$line" =~ ^([A-Za-z0-9-]+):[[:space:]]*(.*)$ ]]; then
     key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
     H["$key"]="$val"
  fi
done
clen="${H[content-length]:-0}"

# ---- read body exactly N bytes (if present) ----
if [[ "$clen" =~ ^[0-9]+$ ]] && [ "$clen" -gt 0 ]; then
  body="$(dd bs=1 count="$clen" 2>/dev/null || true)"
else
  body="$(cat || true)"   # fallback for when Content-Length is missing
fi

# ---- sanitize function: normalize whitespace and remove CR/LF ----
sanitize(){
  local s="${1//$'\r'/}"
  s="${s//$'\n'/ }"
  echo "$s" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

# ---- slugify: generate a safe identifier (for dim=) ----
slugify(){
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  s="${s// /_}"
  s=$(echo -n "$s" | sed 's/[^a-z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//')
  echo -n "$s" | cut -c1-128
}

severity=""; policy=""; documentation=""; subject=""; state_raw=""; cond_name=""; dim=""

# ---- parse JSON with jq when available ----
if command -v jq >/dev/null 2>&1; then
  severity=$(printf '%s' "$body" | jq -r '.incident.severity // .severity // empty')
  policy=$(printf '%s' "$body" | jq -r '.incident.policy_name // .policy_name // empty')
  cond_name=$(printf '%s' "$body" | jq -r '.incident.condition_name // .incident.condition.displayName // empty')
  documentation=$(printf '%s' "$body" | jq -r '
    if (.incident.documentation | type=="object") then
      .incident.documentation.content // .incident.documentation.subject
    elif (.incident.documentation | type=="string") then
      .incident.documentation
    elif (.documentation | type=="object") then
      .documentation.content // .documentation.subject
    elif (.documentation | type=="string") then
      .documentation
    else empty end
  ')
  subject=$(printf '%s' "$body" | jq -r '.incident.documentation.subject // .documentation.subject // empty')
  state_raw=$(printf '%s' "$body" | jq -r '.incident.state // .state // empty' | tr '[:upper:]' '[:lower:]')
fi

# ---- fallback: extract severity from subject if not found ----
if [ -z "$severity" ] && [ -n "$subject" ]; then
  severity=$(printf '%s\n' "$subject" | sed -n 's/.*\[ALERT - \([^]]*\)\].*/\1/p')
fi
# ---- fallback: derive severity from state ----
if [ -z "$severity" ]; then
  case "$state_raw" in
    open)   severity="Open" ;;
    closed) severity="Resolved" ;;
  esac
fi

# ---- cleanup values and apply limits ----
severity=$(sanitize "${severity:-<no_severity>}")
policy=$(sanitize "${policy:-<no_policy>}")
documentation=$(sanitize "${documentation:-<no_documentation>}")
documentation=$(echo -n "$documentation" | cut -c1-512)

# ---- define "dim" (fingerprint): prefer condition_name, fallback to policy ----
if [ -n "$cond_name" ]; then
  dim="$cond_name"
else
  dim="$policy"
fi
[ -z "$dim" ] && dim="unknown"
dim_slug=$(slugify "$dim")

# ---- normalize state ----
state="unknown"
case "$state_raw" in
  open)   state="open" ;;
  closed) state="closed" ;;
esac

# ---- final message (single item string) ----
msg="${severity} | ${policy} | ${documentation} | dim=${dim_slug} | state=${state}"

# ---- send to Zabbix via zabbix_sender ----
zabbix_sender -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "$ZBX_KEY" -o "$msg" >/dev/null 2>&1 || true

# ---- log debug info ----
log "request_line: $request_line"
log "dim: $dim -> $dim_slug | state: $state"
log "Sent: ${ZBX_KEY} = $msg"

# ---- reply HTTP 200 (prevent GCP retries) ----
printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
