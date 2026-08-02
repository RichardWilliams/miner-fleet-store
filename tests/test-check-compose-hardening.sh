#!/usr/bin/env bash
#
# Tests for scripts/check-compose-hardening.sh.
#
# Every case builds its own fixture tree under the harness scratch dir and runs
# the real script against it — no case reads the repo's actual compose file
# (codespace docs/testing-standards.md § 4.1, hermetic fixtures). The script
# resolves its repo root from its own location, so each fixture is a complete
# miniature repo: the script plus the app directory beside it.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-compose-hardening.sh"
readonly APP_ID="pipfox-miner-fleet"

[[ -f "$SCRIPT_UNDER_TEST" ]] || {
  printf 'FATAL: script under test not found at %s\n' "$SCRIPT_UNDER_TEST" >&2
  exit 1
}

# The scratch dir, its single cleanup trap, the counters, assert_case and the
# summary line are shared with the sibling suites.
harness="${script_dir}/lib/bash-test-harness.sh"
[[ -f "$harness" ]] || {
  printf 'FATAL: shared test harness not found at %s\n' "$harness" >&2
  exit 1
}
source "$harness"

# Build a fixture repo. $1 = fixture name, $2 = the whole compose file body.
# Returns the fixture root on stdout.
make_fixture() {
  local name="$1" compose_body="$2"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts" "${root}/${APP_ID}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-compose-hardening.sh"
  chmod +x "${root}/scripts/check-compose-hardening.sh"
  printf '%s\n' "$compose_body" > "${root}/${APP_ID}/docker-compose.yml"
  printf '%s' "$root"
}

# Run the fixture's copy of the script. $1 = case description, $2 = expected
# exit, $3 = fixture root, $4 = substring expected in the output.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-compose-hardening.sh"
}

# The shape the real file has: two services, both hardening directives on
# `server` as block sequences, no host networking, no published port.
readonly COMPOSE_REAL_SHAPE='services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1
      APP_PORT: 3000

  server:
    image: example/app:1.0.0
    restart: on-failure
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - /srv/data:/data'

# REAL SHAPE — the property the gate exists to hold still.
root="$(make_fixture real_shape "$COMPOSE_REAL_SHAPE")"
run_case 'real shape: both directives on server, no host networking, no ports passes' 0 "$root" 'OK: server drops ALL capabilities'

# COMMENT COLLISION, positive direction. The real compose file's own prose names
# `cap_drop: ALL` and `no-new-privileges` repeatedly, so a gate that read a
# comment as content would report a false PASS on a service that lost the
# directive. Both directives are pinned separately: a gate satisfied by either
# one alone is not asserting on the other.
root="$(make_fixture cap_drop_only_in_comment 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - no-new-privileges:true
    # cap_drop: ALL used to live here, alongside no-new-privileges:true.
    #   - ALL
    restart: on-failure')"
run_case 'comment: cap_drop present only inside a comment fails' 1 "$root" "declares no 'cap_drop:' block sequence"

root="$(make_fixture security_opt_only_in_comment 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    cap_drop:
      - ALL
    # security_opt with no-new-privileges:true belongs here.
    #   - no-new-privileges:true
    restart: on-failure')"
run_case 'comment: security_opt present only inside a comment fails' 1 "$root" "declares no 'security_opt:' block sequence"

# SERVICE SCOPING, failing direction. A gate that accepted a directive found
# anywhere in the file would pass on `app_proxy` alone and verify nothing about
# the container that actually runs the app.
root="$(make_fixture hardening_on_app_proxy_only 'services:
  app_proxy:
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    restart: on-failure')"
run_case 'scoping: hardening on app_proxy but absent from server fails' 1 "$root" "declares no 'cap_drop:' block sequence"

# SERVICE SCOPING, passing direction. The mirror case proves the scoping is a
# real restriction rather than a gate that happens to fail on everything: a
# published port on `app_proxy` says nothing about the app container.
root="$(make_fixture ports_on_app_proxy_only 'services:
  app_proxy:
    ports:
      - "8080:80"
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'scoping: a published port on app_proxy alone passes' 0 "$root" 'OK: server drops ALL capabilities'

# NEGATIVE ASSERTIONS on the server service.
root="$(make_fixture network_mode_host 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    network_mode: host
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'negative: network_mode host on server fails' 1 "$root" 'declares network_mode: host'

root="$(make_fixture published_ports 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    ports:
      - "3007:3000"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'negative: a published host port on server fails' 1 "$root" 'publishes a host port'

# NEGATIVE ASSERTIONS must not fire on prose. This is the direction where an
# over-broad comment strip does damage: reading a comment as content turns a
# correct file into a false FAIL, and a gate that cries wolf on its own
# documentation gets deleted.
root="$(make_fixture network_mode_host_in_comment 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    # Bridge networking, NOT network_mode: host (DECISIONS.md entry 2).
    # No ports: either — app_proxy fronts the app on the manifest port.
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'comment: network_mode host and ports named only in comments pass' 0 "$root" 'OK: server drops ALL capabilities'

# TRAILING COMMENT on a hardening line. Valid YAML, and the real file comments
# heavily around exactly these lines, so a strip that swallowed the value would
# false-FAIL a correct file.
root="$(make_fixture trailing_comment_on_hardening 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:       # escalation unavailable, not merely unused
      - no-new-privileges:true  # see DECISIONS.md entry 6
    cap_drop:
      - ALL  # everything; nothing is added back')"
run_case 'comment: trailing comments on hardening lines do not break the match' 0 "$root" 'OK: server drops ALL capabilities'

# A `#` INSIDE A TOKEN is not a comment — YAML requires whitespace before the
# `#`. An over-broad strip would truncate this value to `host` and report a
# false FAIL on a file that declares no host networking at all.
root="$(make_fixture hash_inside_token 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    network_mode: host#0
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'strip: a # inside a token is not treated as a comment' 0 "$root" 'OK: server drops ALL capabilities'

# Only `host` is banned. A gate that rejected every network_mode would block a
# legitimate edit, which fails in the direction that merely looks safe.
root="$(make_fixture network_mode_bridge 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    network_mode: bridge
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'negative: network_mode bridge on server passes' 0 "$root" 'OK: server drops ALL capabilities'

# PRESENT BUT WRONG. The key existing is not the assertion — the value is.
root="$(make_fixture cap_drop_without_all 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - NET_RAW
      - SYS_ADMIN')"
run_case 'value: cap_drop listing individual capabilities instead of ALL fails' 1 "$root" 'does not drop ALL'

root="$(make_fixture security_opt_without_nnp 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - seccomp:unconfined
    cap_drop:
      - ALL')"
run_case 'value: security_opt without no-new-privileges:true fails' 1 "$root" 'does not set no-new-privileges:true'

# QUOTED SEQUENCE VALUES are legal YAML for both directives, and both quote
# styles must resolve to the same bare value.
root="$(make_fixture quoted_sequence_values 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - '"'"'ALL'"'"'')"
run_case 'quoted: double- and single-quoted sequence values pass' 0 "$root" 'OK: server drops ALL capabilities'

# INLINE FLOW FORM. This check parses block sequences only. A flow value is
# refused by name rather than skipped silently and rather than half-parsed by a
# flow reader this gate does not have.
root="$(make_fixture cap_drop_inline_flow 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]')"
run_case 'flow: cap_drop written as an inline flow value is refused' 1 "$root" 'inline flow value'

root="$(make_fixture security_opt_inline_flow 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt: [no-new-privileges:true]
    cap_drop:
      - ALL')"
run_case 'flow: security_opt written as an inline flow value is refused' 1 "$root" 'inline flow value'

# STRUCTURAL FAIL-CLOSED CASES. None of these is a skip.
root="$(make_fixture missing_compose "$COMPOSE_REAL_SHAPE")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
run_case 'missing: absent compose file fails closed' 1 "$root" 'compose file not found'

root="$(make_fixture unreadable_compose "$COMPOSE_REAL_SHAPE")"
chmod 000 "${root}/${APP_ID}/docker-compose.yml"
run_case 'unreadable: permission-denied compose file fails closed with the real cause' 1 "$root" 'compose file not readable'
chmod 644 "${root}/${APP_ID}/docker-compose.yml"

root="$(make_fixture no_services_key 'name: pipfox-miner-fleet
description: a compose file that lost its services block')"
run_case 'structure: absent services: block fails closed' 1 "$root" "no top-level 'services:' key"

root="$(make_fixture no_server_service 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL')"
run_case 'structure: absent server service fails closed' 1 "$root" "no 'server' service found"

root="$(make_fixture empty_server_service 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:')"
run_case 'structure: server service declaring no directives fails closed' 1 "$root" 'declares no directives'

# A line indented deeper than a top-level key but shallower than the service-key
# indent belongs to no service this check can name. Guessing would be the whole
# defect the scoping exists to prevent, so it is a failure.
root="$(make_fixture unclassifiable_indent 'services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1

  server:
    image: example/app:1.0.0
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
 stray: value')"
run_case 'structure: a line between top-level and service-key indent fails closed' 1 "$root" 'unclassifiable indentation'

# YAML forbids tabs for indentation, so a tab-indented line cannot be placed in
# a service by counting spaces.
root="$(make_fixture tab_indent "$(printf 'services:\n  app_proxy:\n    environment:\n      APP_HOST: pipfox-miner-fleet_server_1\n\n  server:\n    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n\trestart: on-failure')")"
run_case 'structure: tab-indented line fails closed' 1 "$root" 'non-space indentation'

report_summary
