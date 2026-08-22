#!/usr/bin/env bash
#
# Tests for scripts/check-deploy-contract.sh.
#
# Every case builds its own miniature repo under the harness scratch dir — the
# gate, the libraries it sources, an app manifest, a compose file and a vendored
# contract — and runs the real script against it (codespace
# docs/testing-standards.md § 4.1, hermetic fixtures). No case reads this repo's
# real compose file, and no case makes a network call: the gate reads a
# committed artefact, so there is nothing to stub.
#
# The required-environment-key coverage is deliberately driven by a SYNTHETIC
# contract carrying a NON-EMPTY required set. The shipped contract's set is
# empty — and empty is the forced answer there, not a gap — so a case built on
# the real contract would assert over an empty loop and pass for the wrong
# reason.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-deploy-contract.sh"
readonly COMMON_LIB="${repo_root}/scripts/lib/check-common.sh"
readonly CONTEXT_LIB="${repo_root}/scripts/lib/repo-context.sh"
readonly PARSER_LIB="${repo_root}/scripts/lib/manifest_data.py"
readonly APP_ID="pipfox-miner-fleet"
readonly VENDOR_DIR="upstream"
readonly PINNED="0.3.0"

for required in "$SCRIPT_UNDER_TEST" "$COMMON_LIB" "$CONTEXT_LIB" "$PARSER_LIB"; do
  [[ -f "$required" ]] || {
    printf 'FATAL: file under test not found at %s\n' "$required" >&2
    exit 1
  }
done

harness="${script_dir}/lib/bash-test-harness.sh"
[[ -f "$harness" ]] || {
  printf 'FATAL: shared test harness not found at %s\n' "$harness" >&2
  exit 1
}
source "$harness"

# ---------------------------------------------------------------------------
# Fixture material. Both bodies come from quoted heredocs so `${APP_DATA_DIR}`
# stays literal and the single quotes inside the healthcheck command survive.
# ---------------------------------------------------------------------------

BASE_CONTRACT="$(cat <<'CONTRACT'
{
  "documentation": {
    "purpose": "Prose the gate ignores by design.",
    "requiredEnvKeysMeaning": "The keys without which the container fails to start.",
    "packagingAffecting": "The facts the packaging depends on.",
    "nonPackagingAffecting": "Tunables that never need a coordinated release."
  },
  "packagingAffecting": {
    "containerPort": 3000,
    "healthPath": "/api/health",
    "dataDirectory": {
      "envKey": "MINER_FLEET_DATA_DIR",
      "default": "/data"
    },
    "requiredEnvKeys": []
  },
  "nonPackagingAffecting": {
    "optionalEnvKeys": [
      { "key": "MINER_FLEET_SUBNETS" }
    ]
  }
}
CONTRACT
)"

BASE_COMPOSE="$(cat <<'COMPOSE'
services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1
      APP_PORT: 3000

  server:
    image: ghcr.io/richardwilliams/miner-fleet:0.3.0@sha256:27c16fba762479efa4773aa477ede79e96f67bb633c554baa1d820f0429419f8
    restart: on-failure
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
    volumes:
      - ${APP_DATA_DIR}/data:/data
    env_file:
      - path: ${APP_DATA_DIR}/data/config.env
        required: false
COMPOSE
)"

# The same compose with the required key declared on the server service — the
# satisfying shape for a non-empty required set.
COMPOSE_WITH_ENVIRONMENT="$(cat <<'COMPOSE'
services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1
      APP_PORT: 3000

  server:
    image: ghcr.io/richardwilliams/miner-fleet:0.3.0@sha256:27c16fba762479efa4773aa477ede79e96f67bb633c554baa1d820f0429419f8
    environment:
      MINER_FLEET_LICENCE_KEY: supplied-by-the-packaging
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
    volumes:
      - ${APP_DATA_DIR}/data:/data
    env_file:
      - path: ${APP_DATA_DIR}/data/config.env
        required: false
COMPOSE
)"

# The same compose whose env_file is declared REQUIRED — compose itself refuses
# to start without the file, which is the other way a key can be guaranteed.
COMPOSE_WITH_REQUIRED_ENV_FILE="$(cat <<'COMPOSE'
services:
  app_proxy:
    environment:
      APP_HOST: pipfox-miner-fleet_server_1
      APP_PORT: 3000

  server:
    image: ghcr.io/richardwilliams/miner-fleet:0.3.0@sha256:27c16fba762479efa4773aa477ede79e96f67bb633c554baa1d820f0429419f8
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
    volumes:
      - ${APP_DATA_DIR}/data:/data
    env_file:
      - path: ${APP_DATA_DIR}/data/config.env
        required: true
COMPOSE
)"

# Derive a contract variant by substituting one JSON fragment for another.
# $1 = source contract, $2 = literal fragment to replace, $3 = replacement.
contract_with() {
  local source="$1" from="$2" to="$3"
  printf '%s' "$source" | python3 -c '
import sys
source = sys.stdin.read()
frm, to = sys.argv[1], sys.argv[2]
if source.count(frm) != 1:
    sys.stderr.write("fixture fragment is not unique: " + frm + "\n")
    raise SystemExit(1)
sys.stdout.write(source.replace(frm, to))
' "$from" "$to"
}

# Build a miniature repo. $1 = name, $2 = contract text, $3 = compose text,
# $4 = vendored directory name. Returns the fixture root.
make_fixture() {
  local name="$1" contract="$2" compose="$3" vendored="$4"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}" "${root}/${VENDOR_DIR}/${vendored}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-deploy-contract.sh"
  chmod +x "${root}/scripts/check-deploy-contract.sh"
  cp "$COMMON_LIB" "${root}/scripts/lib/check-common.sh"
  cp "$CONTEXT_LIB" "${root}/scripts/lib/repo-context.sh"
  cp "$PARSER_LIB" "${root}/scripts/lib/manifest_data.py"

  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
version: "${PINNED}"
port: 3007
EOF

  printf '%s\n' "$compose" > "${root}/${APP_ID}/docker-compose.yml"
  printf '%s\n' "$contract" > "${root}/${VENDOR_DIR}/${vendored}/contract.json"
  printf '%s' "$root"
}

# $1 = description, $2 = expected exit, $3 = fixture root, $4 = substring.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-deploy-contract.sh"
}

# ---------------------------------------------------------------------------
# The shipped shape passes, INCLUDING the documentation.* prose fields and
# nonPackagingAffecting.optionalEnvKeys. The unknown-field rule is scoped to the
# packagingAffecting subtree; an unscoped reading would fail every run.
# ---------------------------------------------------------------------------
root="$(make_fixture happy "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
run_case 'happy: the shipped compose satisfies the shipped contract' 0 "$root" 'OK'
run_case 'happy: documentation and non-packaging-affecting fields are ignored by design' 0 "$root" 'health path /api/health'

# ---------------------------------------------------------------------------
# The three packaging facts, each mismatched in turn. Every message names both
# values so the diagnosis needs no second command.
# ---------------------------------------------------------------------------
root="$(make_fixture port_mismatch \
  "$(contract_with "$BASE_CONTRACT" '"containerPort": 3000' '"containerPort": 4000')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'mismatch: a container-port mismatch fails naming the contract value' 1 "$root" 'declares 4000'
run_case 'mismatch: a container-port mismatch fails naming the compose value' 1 "$root" 'APP_PORT 3000'

root="$(make_fixture health_mismatch \
  "$(contract_with "$BASE_CONTRACT" '"healthPath": "/api/health"' '"healthPath": "/api/healthz"')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'mismatch: a health-path mismatch fails naming the contract value' 1 "$root" 'declares /api/healthz'
run_case 'mismatch: a health-path mismatch fails naming the compose value' 1 "$root" 'probes /api/health'

root="$(make_fixture data_dir_mismatch \
  "$(contract_with "$BASE_CONTRACT" '"default": "/data"' '"default": "/var/lib/miner-fleet"')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'mismatch: a data-directory mismatch fails naming the contract value' 1 "$root" 'declares /var/lib/miner-fleet'
run_case 'mismatch: a data-directory mismatch fails naming the compose mount targets' 1 "$root" 'mount targets: /data'

# ---------------------------------------------------------------------------
# An unrecognised field UNDER packagingAffecting is a failure naming the field.
# A new packaging-affecting fact upstream that this gate ignored is exactly the
# drift the gate exists to catch.
# ---------------------------------------------------------------------------
root="$(make_fixture unknown_field \
  "$(contract_with "$BASE_CONTRACT" '"requiredEnvKeys": []' '"requiredEnvKeys": [], "sidecarPort": 9000')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'unknown field: an unrecognised packagingAffecting field fails by name' 1 "$root" 'sidecarPort'

root="$(make_fixture unknown_nested_field \
  "$(contract_with "$BASE_CONTRACT" '"default": "/data"' '"default": "/data", "mode": "rw"')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'unknown field: an unrecognised dataDirectory field fails by name' 1 "$root" 'packagingAffecting.dataDirectory.mode'

# ---------------------------------------------------------------------------
# FAIL-CLOSED. Every unreadable input is a failure; no path reports a skip.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_contract "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
rm -f "${root}/${VENDOR_DIR}/v${PINNED}/contract.json"
run_case 'fail-closed: a missing contract file fails' 1 "$root" 'vendored deployment contract not found'

root="$(make_fixture absent_contract_field \
  "$(contract_with "$BASE_CONTRACT" '"healthPath": "/api/health",' '')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'fail-closed: an absent contract field fails by name' 1 "$root" "'packagingAffecting.healthPath' is absent"

root="$(make_fixture unreadable_contract_field \
  "$(contract_with "$BASE_CONTRACT" '"dataDirectory": {
      "envKey": "MINER_FLEET_DATA_DIR",
      "default": "/data"
    },' '"dataDirectory": "/data",')" \
  "$BASE_COMPOSE" "v${PINNED}")"
run_case 'fail-closed: a contract field of the wrong shape fails' 1 "$root" 'not a mapping'

root="$(make_fixture unparseable_contract "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
printf '{ "packagingAffecting": { \n' > "${root}/${VENDOR_DIR}/v${PINNED}/contract.json"
run_case 'fail-closed: an unparseable contract fails' 1 "$root" 'not parseable JSON'

root="$(make_fixture unparseable_compose "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
printf 'services:\n  app_proxy:\n    environment:\n      APP_PORT: [3000\n' > "${root}/${APP_ID}/docker-compose.yml"
run_case 'fail-closed: an unparseable compose fails' 1 "$root" 'not parseable YAML'

root="$(make_fixture absent_compose_field "$BASE_CONTRACT" \
  "$(contract_with "$BASE_COMPOSE" '      APP_PORT: 3000' '      APP_OTHER: 3000')" \
  "v${PINNED}")"
run_case 'fail-closed: an absent compose field fails by name' 1 "$root" "no 'services.app_proxy.environment.APP_PORT' found"

root="$(make_fixture healthcheck_without_url "$BASE_CONTRACT" \
  "$(contract_with "$BASE_COMPOSE" \
    "      test: [\"CMD\", \"node\", \"-e\", \"fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\"]" \
    '      test: ["CMD", "true"]')" \
  "v${PINNED}")"
run_case 'fail-closed: a healthcheck test carrying no URL fails' 1 "$root" 'found 0'

root="$(make_fixture missing_compose "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
run_case 'fail-closed: a missing compose file fails' 1 "$root" 'compose file not found'

# ---------------------------------------------------------------------------
# The contract is read at the PINNED tag. The vendored directory is named for
# the version the manifest pins, so a directory naming any other version is not
# where this gate looks — which is what makes "never main, never unpinned"
# checkable with no network at all.
# ---------------------------------------------------------------------------
root="$(make_fixture pinned_tag_only "$BASE_CONTRACT" "$BASE_COMPOSE" 'v0.2.0')"
run_case 'pinned tag: a contract vendored under another version is not read' 1 "$root" "${VENDOR_DIR}/v${PINNED}/contract.json"

root="$(make_fixture unparseable_pin "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
printf 'manifestVersion: 1\nid: %s\nversion: "main"\nport: 3007\n' "$APP_ID" \
  > "${root}/${APP_ID}/umbrel-app.yml"
run_case 'pinned tag: a manifest version that is not a semver fails' 1 "$root" 'is not a semver'

# ---------------------------------------------------------------------------
# REQUIRED ENVIRONMENT KEYS, driven by a synthetic contract with a NON-EMPTY
# set. The shipped set is empty, so these are the only cases that exercise the
# assertion at all.
#
# The satisfaction rule follows the contract's own definition of the set: keys
# WITHOUT WHICH THE CONTAINER FAILS TO START. An env_file the compose declares
# OPTIONAL — which is what this store ships, so a fresh install with no operator
# file starts cleanly — guarantees nothing, so it satisfies nothing.
# ---------------------------------------------------------------------------
REQUIRED_KEY_CONTRACT="$(contract_with "$BASE_CONTRACT" \
  '"requiredEnvKeys": []' '"requiredEnvKeys": ["MINER_FLEET_LICENCE_KEY"]')"

root="$(make_fixture required_key_unsatisfiable "$REQUIRED_KEY_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
run_case 'required keys: a key no compose environment supplies fails by name' 1 "$root" 'MINER_FLEET_LICENCE_KEY'
run_case 'required keys: an optional env_file does not satisfy a required key' 1 "$root" 'every declared env_file is optional'

root="$(make_fixture required_key_in_environment "$REQUIRED_KEY_CONTRACT" "$COMPOSE_WITH_ENVIRONMENT" "v${PINNED}")"
run_case 'required keys: a key declared in the server environment satisfies the contract' 0 "$root" '1 required environment key'

root="$(make_fixture required_key_via_required_env_file "$REQUIRED_KEY_CONTRACT" "$COMPOSE_WITH_REQUIRED_ENV_FILE" "v${PINNED}")"
run_case 'required keys: an env_file declared required satisfies the contract' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# The compose is consumed as ASSERTIONS ONLY. It is never generated, templated
# or rewritten from the contract — on a passing run or a failing one.
# ---------------------------------------------------------------------------
readonly UNTOUCHED_CHECK="${scratch}/assert-compose-untouched.sh"
cat > "$UNTOUCHED_CHECK" <<'UNTOUCHED'
#!/usr/bin/env bash
# $1 = gate script, $2 = compose path
set -euo pipefail
before="$(mktemp)"
cp "$2" "$before"
gate_exit=0
bash "$1" >/dev/null 2>&1 || gate_exit=$?
if ! cmp -s "$before" "$2"; then
  rm -f "$before"
  printf 'the gate rewrote the compose file\n' >&2
  exit 1
fi
rm -f "$before"
printf 'compose byte-identical after a gate run that exited %d\n' "$gate_exit"
UNTOUCHED

root="$(make_fixture assert_only_pass "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
assert_case 'assertions only: a passing run leaves the compose byte-identical' 0 'byte-identical' \
  bash "$UNTOUCHED_CHECK" "${root}/scripts/check-deploy-contract.sh" "${root}/${APP_ID}/docker-compose.yml"

root="$(make_fixture assert_only_fail \
  "$(contract_with "$BASE_CONTRACT" '"containerPort": 3000' '"containerPort": 4000')" \
  "$BASE_COMPOSE" "v${PINNED}")"
assert_case 'assertions only: a failing run leaves the compose byte-identical' 0 'byte-identical' \
  bash "$UNTOUCHED_CHECK" "${root}/scripts/check-deploy-contract.sh" "${root}/${APP_ID}/docker-compose.yml"

# ---------------------------------------------------------------------------
# The explicit-path form the release driver uses is the SAME assertion, not a
# weaker one: it fails on the same mismatch.
# ---------------------------------------------------------------------------
root="$(make_fixture explicit_paths "$BASE_CONTRACT" "$BASE_COMPOSE" "v${PINNED}")"
assert_case 'explicit paths: --contract and --compose run the same assertion' 0 'OK' \
  bash "${root}/scripts/check-deploy-contract.sh" \
  --contract "${root}/${VENDOR_DIR}/v${PINNED}/contract.json" \
  --compose "${root}/${APP_ID}/docker-compose.yml"

root="$(make_fixture explicit_paths_mismatch \
  "$(contract_with "$BASE_CONTRACT" '"containerPort": 3000' '"containerPort": 4000')" \
  "$BASE_COMPOSE" "v${PINNED}")"
assert_case 'explicit paths: a mismatch still fails under --contract and --compose' 1 'container-port mismatch' \
  bash "${root}/scripts/check-deploy-contract.sh" \
  --contract "${root}/${VENDOR_DIR}/v${PINNED}/contract.json" \
  --compose "${root}/${APP_ID}/docker-compose.yml"

assert_case 'arguments: an unrecognised argument fails' 1 'unrecognised argument' \
  bash "${root}/scripts/check-deploy-contract.sh" --contrct /nowhere

report_summary
