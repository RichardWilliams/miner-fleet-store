#!/usr/bin/env bash
#
# Fail when this repo's compose file no longer satisfies the upstream
# deployment contract for the version it pins.
#
# `pipfox-miner-fleet/docker-compose.yml` hardcodes three facts the miner-fleet
# repo owns: the container port, the health path, and the data-directory mount
# target. Nothing tied them to their source, so an upstream rename or move kept
# shipping stale values here and surfaced as a crash loop on the operator's box
# with nothing in this repo's diff to explain it. miner-fleet now publishes a
# generated `deploy/contract.json` declaring those facts; this gate asserts the
# compose still satisfies it.
#
# ASSERTIONS ONLY — NEVER GENERATION. This gate reads the contract and reads the
# compose. It does not write, template, rewrite or emit any part of the compose,
# and it never will: that file is half Umbrel packaging contract (`app_proxy`,
# the `_server_1` APP_HOST naming rule, `${APP_DATA_DIR}` interpolation) and it
# carries load-bearing explanatory comments a generator would flatten.
# miner-fleet publishes a contract; this repo asserts against it. That direction
# is permanent and is recorded in DECISIONS.md entry 12.
#
# NO NETWORK. The contract read is against the copy `scripts/release.sh`
# vendored at bump time under `upstream/v<version>/`, fetched there at tag
# `v<version>` — never at `main`, never at an unpinned ref. The version-encoded
# directory name is what makes "fetched at the pinned tag" checkable with no
# network at all. DECISIONS.md entry 13 is the single networked-gate policy both
# gates follow.
#
# WHAT THIS GATE DOES AND DOES NOT GUARANTEE ABOUT STALENESS. It DERIVES the
# contract path from the version the manifest pins, so it can only ever read
# `upstream/v<pinned>/contract.json`: a directory naming a different version
# cannot satisfy it, and an absent one fails it closed. What it does NOT do is
# notice a SECOND, stale `upstream/vX.Y.Z/` directory sitting beside the pinned
# one — it would go on reading the correct one and pass. That "exactly one
# vendored directory" check is written once, in `check-release-notes-drift.sh`,
# and it is a property of the SUITE rather than a coupling implemented here:
# `.local-ci.yml` runs both gates on every push and DEPLOY.md § 3.1 lists both
# in the hand-edit recovery path, so the stale-sibling case is caught wherever
# this gate reads a VENDORED contract. Running this gate ALONE would not catch
# it, and nothing in the code below claims otherwise. `scripts/release.sh`
# step 6 is exactly that alone invocation — and it is not a gap, because it
# passes a STAGED contract by path, so no vendored directory is consulted and
# there is no stale sibling to miss.
#
# SCOPE — the `packagingAffecting` subtree, deliberately. An unrecognised field
# under `packagingAffecting` is a FAILURE naming the field, because a new
# packaging-affecting fact added upstream that this gate ignored is exactly the
# drift it exists to catch. The contract also carries `documentation.*` prose and
# `nonPackagingAffecting.optionalEnvKeys`; neither is assertable against a
# compose file, and a non-packaging-affecting field never requires a coordinated
# store bump — that is precisely what the upstream structural split exists to
# express. So this gate ignores them BY DESIGN, not by omission, and an unscoped
# reading of the unknown-field rule would fail every run.
#
# FAIL-CLOSED. A missing contract, an absent or unreadable contract field, an
# unparseable value on either side, and a compose shape this gate does not read
# are all FAILURES, never a skip. tests/test-check-deploy-contract.sh has a
# fail-closed section covering these inputs.
#
# usage: check-deploy-contract.sh [--contract <path>] [--compose <path>]
#
# With no arguments both inputs are resolved from the repo, which is how
# `.local-ci.yml` runs it. `scripts/release.sh` passes explicit paths so it can
# assert a freshly fetched contract against the current compose BEFORE it writes
# a single byte into the tree — the same assertion on named inputs, not a
# weaker one.

set -euo pipefail

# The repo root is derived from this script's own location so both invocation
# styles behave the same wherever they are run from.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

# Both libraries below are shared, each with one definition for the whole repo.
# fail() lives in scripts/lib/check-common.sh; the app id, the
# vendored-artefact paths and the semver shape live in
# scripts/lib/repo-context.sh (INVARIANTS.md § Encapsulation).
source "${script_dir}/lib/check-common.sh"
source "${script_dir}/lib/repo-context.sh"

readonly HELPER="${script_dir}/lib/manifest_data.py"

contract=""
compose=""
while (( $# > 0 )); do
  case "$1" in
    --contract)
      (( $# >= 2 )) || fail "--contract needs a path"
      contract="$2"
      shift 2
      ;;
    --compose)
      (( $# >= 2 )) || fail "--compose needs a path"
      compose="$2"
      shift 2
      ;;
    *)
      fail "unrecognised argument '$1' — usage: check-deploy-contract.sh [--contract <path>] [--compose <path>]"
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 \
  || fail "python3 not found on PATH; this gate parses the contract and the compose with it because the pinned CI image ships no jq and no yq"
[[ -f "$HELPER" ]] || fail "shared manifest parser not found at ${HELPER}"

[[ -n "$compose" ]] || compose="${repo_root}/${COMPOSE_REL_PATH}"
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"

# The contract's default location is derived from the version the manifest pins,
# which is what ties the assertion to the tag rather than to whatever happens to
# be vendored.
if [[ -z "$contract" ]]; then
  manifest="${repo_root}/${MANIFEST_REL_PATH}"
  [[ -f "$manifest" ]] || fail "app manifest not found at ${manifest}"
  pinned="$(python3 "$HELPER" get "$manifest" version 2>&1)" || fail "$pinned"
  [[ "$pinned" =~ ^${SEMVER_ERE}$ ]] \
    || fail "manifest version '${pinned}' is not a semver, so no vendored contract path can be derived from it"
  contract="${repo_root}/$(vendor_rel_path "$pinned" "$VENDOR_CONTRACT_NAME")"
fi
[[ -f "$contract" ]] || fail "vendored deployment contract not found at ${contract} — scripts/release.sh fetches it at the pinned tag and writes it there"

# Every read goes through the shared parser and reports its own diagnostic, so
# no caller has to decide what an empty result meant.
read_contract() {
  local out=""
  out="$(python3 "$HELPER" get "$contract" "$@" 2>&1)" || fail "$out"
  printf '%s' "$out"
}

read_compose() {
  local out=""
  out="$(python3 "$HELPER" get "$compose" "$@" 2>&1)" || fail "$out"
  printf '%s' "$out"
}

# read_lines <target-array-name> <helper-op> <file> <path...> — run a helper
# operation that prints one item per line and load the result into the named
# array, leaving it EMPTY rather than holding one empty string when the helper
# printed nothing.
read_lines() {
  local -n target="$1"
  local operation="$2" file="$3"
  shift 3
  local out=""
  out="$(python3 "$HELPER" "$operation" "$file" "$@" 2>&1)" || fail "$out"
  target=()
  [[ -n "$out" ]] || return 0
  mapfile -t target <<< "$out"
}

# --- 1. no unrecognised packaging-affecting field ----------------------------
#
# Checked FIRST: a field this gate has never heard of means the contract has
# moved somewhere this gate no longer covers, which makes every assertion below
# it a statement about an incomplete reading.

assert_exact_fields() {
  local label="$1" path_spec="$2"
  shift 2
  local -a known=("$@")
  local -a path=()
  read -r -a path <<< "$path_spec"
  local -a present=()
  read_lines present keys "$contract" "${path[@]}"

  local field="" candidate="" seen=0
  for field in "${present[@]}"; do
    seen=0
    for candidate in "${known[@]}"; do
      if [[ "$field" == "$candidate" ]]; then
        seen=1
        break
      fi
    done
    if (( seen == 0 )); then
      fail "unrecognised field '${label}.${field}' in ${contract} — a new packaging-affecting fact upstream that this gate does not assert would be silently ignored, which is the drift it exists to catch. Extend this gate to cover it, in the same change that pins the release carrying it."
    fi
  done

  for candidate in "${known[@]}"; do
    seen=0
    for field in "${present[@]}"; do
      if [[ "$field" == "$candidate" ]]; then
        seen=1
        break
      fi
    done
    if (( seen == 0 )); then
      fail "contract field '${label}.${candidate}' is absent from ${contract} — an assertion this gate makes would have no input, so it would verify nothing"
    fi
  done
}

assert_exact_fields packagingAffecting "packagingAffecting" \
  containerPort healthPath dataDirectory requiredEnvKeys
assert_exact_fields packagingAffecting.dataDirectory "packagingAffecting dataDirectory" \
  envKey default

# --- 2. container port <-> app_proxy APP_PORT --------------------------------

contract_port="$(read_contract packagingAffecting containerPort)"
compose_port="$(read_compose services app_proxy environment APP_PORT)"
if [[ "$contract_port" != "$compose_port" ]]; then
  fail "container-port mismatch: the contract declares ${contract_port} but ${COMPOSE_REL_PATH}'s app_proxy sets APP_PORT ${compose_port}. app_proxy would proxy to a port nothing listens on."
fi

# --- 3. health path <-> the healthcheck test's URL path ----------------------

health_path="$(read_contract packagingAffecting healthPath)"
healthcheck_test=()
read_lines healthcheck_test seq "$compose" services server healthcheck test

# POSIX ERE only — no \d, \s or \b (INVARIANTS.md § Tool invocation correctness).
# The bracket expression stops the match at the quote or paren that closes the
# call the URL sits inside, which is how the URL is spelled in this compose.
readonly URL_ERE="https?://[^[:space:]'\")]+"
found_urls=()
matched=""
matched="$(printf '%s\n' "${healthcheck_test[@]}" | grep -oE "$URL_ERE" || true)"
if [[ -n "$matched" ]]; then
  mapfile -t found_urls <<< "$matched"
fi
if (( ${#found_urls[@]} != 1 )); then
  fail "expected exactly one URL in the server healthcheck test in ${COMPOSE_REL_PATH}, found ${#found_urls[@]} — this gate cannot decide which one the contract's health path should match"
fi
compose_health_path="$(printf '%s' "${found_urls[0]}" | sed -E 's#^https?://[^/]*##')"
if [[ "$compose_health_path" != "$health_path" ]]; then
  fail "health-path mismatch: the contract declares ${health_path} but ${COMPOSE_REL_PATH}'s healthcheck probes ${compose_health_path}. The container would report unhealthy while serving correctly."
fi

# --- 4. data-directory default <-> a server volume mount target --------------

data_default="$(read_contract packagingAffecting dataDirectory default)"
declared_volumes=()
read_lines declared_volumes seq "$compose" services server volumes

mount_targets=()
target_found=0
for volume in "${declared_volumes[@]}"; do
  # Short syntax is SOURCE:TARGET[:MODE]; an entry with no colon names the
  # target alone. The long mapping syntax is not read here — `seq` fails by name
  # on a non-scalar entry rather than guessing at it.
  if [[ "$volume" == *:* ]]; then
    mount_target="${volume#*:}"
    mount_target="${mount_target%%:*}"
  else
    mount_target="$volume"
  fi
  mount_targets+=("$mount_target")
  if [[ "$mount_target" == "$data_default" ]]; then
    target_found=1
  fi
done
if (( target_found == 0 )); then
  fail "data-directory mismatch: the contract declares ${data_default} but no ${COMPOSE_REL_PATH} server volume mounts onto it (mount targets: ${mount_targets[*]}). State would be written to an unmounted path and discarded on the next restart."
fi

# --- 5. every required environment key is satisfiable ------------------------
#
# "Satisfiable" is decided against the contract's own definition of the set:
# requiredEnvKeys names the keys WITHOUT WHICH THE CONTAINER FAILS TO START. So
# a key counts as satisfied only when the packaging GUARANTEES it is supplied —
# declared in the `server` service's `environment`, or carried by an `env_file`
# the compose declares REQUIRED, whose absence compose itself refuses to start
# on. The `env_file` this store ships is declared `required: false`
# (DECISIONS.md entry 7) precisely so a fresh install with no operator file yet
# starts cleanly, so it is not a guarantee and satisfies nothing here. That is
# why the shipped set is empty rather than merely happening to be — the contract
# says so itself, in `documentation.requiredEnvKeysMeaning`.

required_count="$(python3 "$HELPER" len "$contract" packagingAffecting requiredEnvKeys 2>&1)" \
  || fail "$required_count"

if (( required_count > 0 )); then
  required_keys=()
  read_lines required_keys seq "$contract" packagingAffecting requiredEnvKeys

  environment_keys=()
  env_kind=""
  env_kind="$(python3 "$HELPER" kind "$compose" services server environment 2>&1)" || fail "$env_kind"
  case "$env_kind" in
    absent) ;;
    mapping) read_lines environment_keys keys "$compose" services server environment ;;
    *)
      fail "the server service's 'environment' in ${COMPOSE_REL_PATH} is a ${env_kind}; this gate reads the mapping form, as app_proxy already uses. Write it as a mapping so the required-key assertion has a set of keys to read."
      ;;
  esac

  guaranteed_env_file=0
  env_file_kind=""
  env_file_kind="$(python3 "$HELPER" kind "$compose" services server env_file 2>&1)" || fail "$env_file_kind"
  if [[ "$env_file_kind" == "sequence" ]]; then
    env_file_count="$(python3 "$HELPER" len "$compose" services server env_file 2>&1)" || fail "$env_file_count"
    for (( position = 0; position < env_file_count; position++ )); do
      entry_kind=""
      entry_kind="$(python3 "$HELPER" kind "$compose" services server env_file "$position" 2>&1)" || fail "$entry_kind"
      if [[ "$entry_kind" == "scalar" ]]; then
        # Short syntax: compose refuses to start when the file is absent, so the
        # file itself is guaranteed.
        guaranteed_env_file=1
        continue
      fi
      if [[ "$entry_kind" != "mapping" ]]; then
        fail "server env_file entry ${position} in ${COMPOSE_REL_PATH} is a ${entry_kind}; this gate reads the short string form and the long mapping form only"
      fi
      required_kind=""
      required_kind="$(python3 "$HELPER" kind "$compose" services server env_file "$position" required 2>&1)" || fail "$required_kind"
      if [[ "$required_kind" == "absent" ]]; then
        # Long syntax defaults `required` to true.
        guaranteed_env_file=1
        continue
      fi
      entry_required="$(read_compose services server env_file "$position" required)"
      if [[ "$entry_required" == "true" ]]; then
        guaranteed_env_file=1
      fi
    done
  fi

  for key in "${required_keys[@]}"; do
    satisfied=0
    for declared_key in "${environment_keys[@]}"; do
      if [[ "$declared_key" == "$key" ]]; then
        satisfied=1
        break
      fi
    done
    if (( satisfied == 0 && guaranteed_env_file == 1 )); then
      satisfied=1
    fi
    if (( satisfied == 0 )); then
      fail "required environment key '${key}' is not satisfiable by ${COMPOSE_REL_PATH}: it is absent from the server service's environment, and every declared env_file is optional, so nothing guarantees the key reaches a container that fails to start without it. The container would crash-loop on the operator's box."
    fi
  done
fi

# Repo-relative labels, so the success line carries no absolute host path.
printf 'check-deploy-contract: OK: %s satisfies %s — port %s, health path %s, data directory %s, %s required environment key(s)\n' \
  "${compose#"${repo_root}/"}" "${contract#"${repo_root}/"}" "$compose_port" "$health_path" "$data_default" "$required_count"
