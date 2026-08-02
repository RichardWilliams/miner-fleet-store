#!/usr/bin/env bash
#
# Fail when the compose file's `server` service loses the hardening the rest of
# this repo's decisions depend on: `cap_drop: ALL` and `no-new-privileges:true`
# (DECISIONS.md entry 6), no `network_mode: host` (entry 2), and no published
# host port — the app is reached through Umbrel's `app_proxy` (entry 1).
#
# SCOPE. The `server` service ONLY. `app_proxy` is Umbrel's injected
# reverse-proxy; its directives say nothing about the app container, so a gate
# that accepted a directive found anywhere in the file would pass on `app_proxy`
# alone and verify nothing. With no YAML parser available, service membership is
# tracked by indentation: the first key under `services:` fixes the service-key
# indent, a later key at that indent starts a new service, deeper lines belong to
# the current one, and indent 0 ends the block.
#
# FAIL-CLOSED. A missing or unreadable file, an absent `services:` block, an
# absent `server` service, a line whose indentation fits none of those shapes,
# and a directive written in an inline flow form this check does not parse are
# all FAILURES, never skips.

set -euo pipefail

# Resolved from this script's own location, so the check runs from anywhere.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

readonly APP_ID="pipfox-miner-fleet"
readonly SERVICE="server"
compose="${repo_root}/${APP_ID}/docker-compose.yml"

fail() {
  printf 'check-compose-hardening: FAIL: %s\n' "$1" >&2
  exit 1
}

# Guard order: existence, then readability, before any parsing — so a permission
# problem names its real cause instead of falling through to a parse diagnostic.
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"
[[ -r "$compose" ]] || fail "compose file not readable at ${compose}"

# POSIX ERE only — no \d, \s or \b (INVARIANTS.md § Tool invocation correctness).
readonly KEY_ERE='[A-Za-z0-9_.-]+'
readonly SERVICE_KEY_ERE="^[[:space:]]*(${KEY_ERE}):[[:space:]]*$"
readonly PORTS_KEY_ERE='^[[:space:]]*ports:'
# Quote handling enumerates three whole forms because POSIX ERE has no
# backreference, so `['\"]?VALUE['\"]?` would accept a mismatched pair.
readonly ITEM_ERE="[^[:space:]\"']+"
readonly SEQUENCE_ITEM_ERE="^[[:space:]]*-[[:space:]]+(\"(${ITEM_ERE})\"|'(${ITEM_ERE})'|(${ITEM_ERE}))[[:space:]]*$"
readonly NETWORK_HOST_ERE="^[[:space:]]*network_mode:[[:space:]]+(\"host\"|'host'|host)[[:space:]]*$"

# Comment handling, in one pass. This file's own prose names `cap_drop: ALL`,
# `no-new-privileges`, `network_mode: host` and ports repeatedly, so a gate that
# read comments as content would report a false PASS on the two positive
# assertions and a false FAIL on the two negative ones.
#
# Rule 1 blanks whole-line comments at any indent. Rule 2 strips a trailing
# comment, and REQUIRES whitespace before the `#` because that is what YAML
# requires — so a `#` inside a token (`host#0`) is left intact rather than
# truncating the value to something the negative assertions would then miss.
stripped="$(sed -E -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]+#.*$//' "$compose")"
lines=()
mapfile -t lines <<< "$stripped"

# Locate the top-level `services:` key.
services_index=-1
for (( i = 0; i < ${#lines[@]}; i++ )); do
  if [[ "${lines[$i]}" =~ ^services:[[:space:]]*$ ]]; then
    services_index=$i
    break
  fi
done
if (( services_index < 0 )); then
  fail "no top-level 'services:' key found in ${APP_ID}/docker-compose.yml — this check could not locate the service block it asserts on, so it verified nothing."
fi

# Walk the block, classifying every line by indent and collecting the `server`
# service's own lines.
service_indent=-1
current_service=""
seen_server=0
server_lines=()
server_indents=()

for (( i = services_index + 1; i < ${#lines[@]}; i++ )); do
  line="${lines[$i]}"
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  [[ "$line" =~ ^([[:space:]]*) ]]
  leading="${BASH_REMATCH[1]}"
  if [[ "$leading" == *[!\ ]* ]]; then
    fail "non-space indentation on line '${line}' in ${APP_ID}/docker-compose.yml — YAML forbids tabs for indentation and this check cannot place the line in a service, so it refuses rather than guessing."
  fi
  indent=${#leading}

  # Indent 0 is a top-level key: the `services:` block has ended.
  (( indent == 0 )) && break

  (( service_indent < 0 )) && service_indent=$indent

  if (( indent == service_indent )); then
    if [[ ! "$line" =~ $SERVICE_KEY_ERE ]]; then
      fail "unclassifiable indentation: line '${line}' in ${APP_ID}/docker-compose.yml sits at the service-key indent (${service_indent}) but is not a '<name>:' service key, so this check cannot tell which service it belongs to."
    fi
    current_service="${BASH_REMATCH[1]}"
    [[ "$current_service" == "$SERVICE" ]] && seen_server=1
    continue
  fi

  if (( indent < service_indent )); then
    fail "unclassifiable indentation: line '${line}' in ${APP_ID}/docker-compose.yml is indented ${indent}, deeper than a top-level key but shallower than the service-key indent (${service_indent}). A line this check cannot attribute to a service is a failure, not a skip."
  fi

  if [[ "$current_service" == "$SERVICE" ]]; then
    server_lines+=("$line")
    server_indents+=("$indent")
  fi
done

if (( seen_server == 0 )); then
  fail "no '${SERVICE}' service found under 'services:' in ${APP_ID}/docker-compose.yml — the service name is a hard naming contract (DECISIONS.md entry 1) and this check has nothing to assert on without it."
fi
if (( ${#server_lines[@]} == 0 )); then
  fail "the '${SERVICE}' service in ${APP_ID}/docker-compose.yml declares no directives, so this check verified nothing."
fi

# Collect the block-sequence entries declared under <key> on the server service
# into `sequence_items`. Returns non-zero when the key is absent; refuses
# outright when the key carries an inline value this check does not parse.
sequence_items=()
collect_sequence() {
  local key="$1"
  local key_indent=-1 i
  sequence_items=()
  for (( i = 0; i < ${#server_lines[@]}; i++ )); do
    if (( key_indent < 0 )); then
      if [[ "${server_lines[$i]}" =~ ^[[:space:]]*${key}:[[:space:]]*$ ]]; then
        key_indent="${server_indents[$i]}"
      elif [[ "${server_lines[$i]}" =~ ^[[:space:]]*${key}:[[:space:]]*[^[:space:]] ]]; then
        fail "'${key}:' on the ${SERVICE} service is written as an inline flow value ('${server_lines[$i]}') in ${APP_ID}/docker-compose.yml. This check parses block sequences only; it does not parse the flow form, so it refuses rather than reporting a result it never established. Write '${key}:' as a block sequence."
      fi
      continue
    fi
    (( server_indents[i] <= key_indent )) && break
    if [[ ! "${server_lines[$i]}" =~ $SEQUENCE_ITEM_ERE ]]; then
      break
    fi
    # Exactly one of the three quote-form groups matched; the rest are empty.
    sequence_items+=("${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}")
  done
  [[ "$key_indent" -ge 0 ]]
}

sequence_contains() {
  local want="$1" item
  for item in ${sequence_items[@]+"${sequence_items[@]}"}; do
    [[ "$item" == "$want" ]] && return 0
  done
  return 1
}

collect_sequence cap_drop \
  || fail "the ${SERVICE} service declares no 'cap_drop:' block sequence in ${APP_ID}/docker-compose.yml. Dropping all capabilities is what makes privilege escalation unavailable to the app container (DECISIONS.md entry 6)."
sequence_contains ALL \
  || fail "the ${SERVICE} service's 'cap_drop:' does not drop ALL in ${APP_ID}/docker-compose.yml — it lists '${sequence_items[*]}'. Restore '- ALL' (DECISIONS.md entry 6)."

collect_sequence security_opt \
  || fail "the ${SERVICE} service declares no 'security_opt:' block sequence in ${APP_ID}/docker-compose.yml. Restore '- no-new-privileges:true' (DECISIONS.md entry 6)."
sequence_contains 'no-new-privileges:true' \
  || fail "the ${SERVICE} service's 'security_opt:' does not set no-new-privileges:true in ${APP_ID}/docker-compose.yml — it lists '${sequence_items[*]}'. Restore it (DECISIONS.md entry 6)."

for line in "${server_lines[@]}"; do
  if [[ "$line" =~ $NETWORK_HOST_ERE ]]; then
    fail "the ${SERVICE} service declares network_mode: host in ${APP_ID}/docker-compose.yml ('${line}'). Bridge networking already reaches the miners, and host networking costs the app_proxy auth layer in front of the app (DECISIONS.md entry 2)."
  fi
  if [[ "$line" =~ $PORTS_KEY_ERE ]]; then
    fail "the ${SERVICE} service publishes a host port in ${APP_ID}/docker-compose.yml ('${line}'). Umbrel reaches the app through app_proxy on the manifest's 'port:', so a published port would expose the app container bypassing that auth layer (DECISIONS.md entry 1)."
  fi
done

printf 'check-compose-hardening: OK: %s drops ALL capabilities, sets no-new-privileges:true, and declares neither host networking nor a published port\n' "$SERVICE"
