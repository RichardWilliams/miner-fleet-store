#!/usr/bin/env bash
#
# Tests for scripts/check-secret-leak.sh and for the shared credential shapes it
# reads from scripts/lib/secret-patterns.sh.
#
# Every case builds its own miniature repo under the harness scratch dir — the
# gate, the libraries it sources, an app manifest, a compose file and a vendored
# upstream directory — and runs the real script against it (codespace
# docs/testing-standards.md § 4.1, hermetic fixtures). No case reads this repo's
# real manifest and no case makes a network call: the gate reads committed files
# and nothing else, so there is nothing to stub.
#
# THE FIXTURE CREDENTIALS ARE NOT CREDENTIALS. The AWS row uses the key id AWS
# itself publishes in its own documentation as the example value, and every other
# row is EXAMPLE filler at the length the shape requires. They match the patterns
# and unlock nothing, which is what a test of a shape-matcher needs.
#
# TWO PROPERTIES THAT ARE EASY TO LOSE AND ARE PINNED HERE:
#
#   * The refusal must never echo the matched text — a message quoting the
#     credential discloses it again, into the terminal and the CI log. Asserted
#     by running the gate and checking the credential is ABSENT from its output,
#     which the harness's substring contract cannot express on its own.
#   * A private-range subnet literal must NOT be refused. This app sweeps the
#     operator's LAN and its release notes say so, so a check that blocked
#     `192.168.1.0/24` would block correct releases (DECISIONS.md entry 15).

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-secret-leak.sh"
readonly COMMON_LIB="${repo_root}/scripts/lib/check-common.sh"
readonly CONTEXT_LIB="${repo_root}/scripts/lib/repo-context.sh"
readonly PATTERNS_LIB="${repo_root}/scripts/lib/secret-patterns.sh"

for required in "$SCRIPT_UNDER_TEST" "$COMMON_LIB" "$CONTEXT_LIB" "$PATTERNS_LIB"; do
  [[ -f "$required" ]] || {
    printf 'FATAL: file under test not found at %s\n' "$required" >&2
    exit 1
  }
done

# The app id and the vendored-artefact paths come from the one place that
# declares them, the same way tests/test-release.sh does.
source "$CONTEXT_LIB"

harness="${script_dir}/lib/bash-test-harness.sh"
[[ -f "$harness" ]] || {
  printf 'FATAL: shared test harness not found at %s\n' "$harness" >&2
  exit 1
}
source "$harness"

# ---------------------------------------------------------------------------
# Fixture material.
# ---------------------------------------------------------------------------

readonly PINNED="0.3.0"

# One row per category in scripts/lib/secret-patterns.sh, plus the label each is
# expected to be reported under. Index-aligned, for the same reason the library's
# own two arrays are.
readonly SECRET_VALUES=(
  'AKIAIOSFODNN7EXAMPLE'
  'ghp_EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPL0'
  'github_pat_EXAMPLEEXAMPLEEXAMPLE1234'
  '-----BEGIN RSA PRIVATE KEY-----'
  'sk-EXAMPLEEXAMPLEEXAMPLEEXAMPLE12'
)
readonly SECRET_LABELS=(
  'an AWS access-key ID'
  'a GitHub token'
  'a GitHub token'
  'a PEM private-key header'
  'an sk- style API key'
)
readonly SECRET_NAMES=(
  'an AWS access-key ID'
  'a classic GitHub token'
  'a fine-grained GitHub PAT'
  'a PEM private-key header'
  'an sk- style API key'
)

# The shipped-shape release body. It deliberately carries the private-range
# subnet, a loopback address and a CIDR mask, because that is what this app's
# real operator guidance says and none of it may be refused.
readonly CLEAN_BODY='Miner Fleet 0.3.0

Firmware versions are now visible across the fleet.

One setup step: create "config.env" on the box and set
MINER_FLEET_SUBNETS=192.168.1.0/24 so discovery sweeps your LAN rather than the
container'"'"'s own bridge network at 172.17.0.0/16. The health probe still
answers on 127.0.0.1 inside the container.

  - discovery
  - telemetry'

readonly CLEAN_CONTRACT='{
  "documentation": {
    "purpose": "Prose the gate reads but does not interpret."
  },
  "packagingAffecting": {
    "containerPort": 3000
  }
}'

readonly CLEAN_COMPOSE="services:
  server:
    image: ${UPSTREAM_IMAGE}:${PINNED}
    restart: on-failure"

# Build a miniature repo. $1 = fixture name. Returns the fixture root.
#
# The vendored artefacts sit where scripts/release.sh would have written them,
# read from the same declaration the driver reads. This gate is the one that
# never derives that path itself — it walks the vendored root recursively — so a
# name spelled out here would be a name nothing could contradict, green against a
# declaration production code had already moved off.
make_fixture() {
  local name="$1"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}" \
    "${root}/$(vendor_rel_path "$PINNED")"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-secret-leak.sh"
  chmod +x "${root}/scripts/check-secret-leak.sh"
  cp "$COMMON_LIB" "${root}/scripts/lib/check-common.sh"
  cp "$CONTEXT_LIB" "${root}/scripts/lib/repo-context.sh"
  cp "$PATTERNS_LIB" "${root}/scripts/lib/secret-patterns.sh"

  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
version: "${PINNED}"
port: 3007
releaseNotes: >-
  The fleet is live.
developer: Pipfox
EOF

  printf '%s\n' "$CLEAN_COMPOSE" > "${root}/${APP_ID}/docker-compose.yml"
  printf '%s\n' "$CLEAN_BODY" \
    > "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"
  printf '%s\n' "$CLEAN_CONTRACT" \
    > "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_CONTRACT_NAME")"

  printf '%s' "$root"
}

# $1 = case description, $2 = expected exit, $3 = fixture root, $4 = substring.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-secret-leak.sh"
}

# A standalone run-and-check-absence helper: assert_case can require a substring
# to be PRESENT, and the property here is that one is ABSENT.
readonly NO_ECHO_CHECK="${scratch}/assert-secret-not-echoed.sh"
cat > "$NO_ECHO_CHECK" <<'NOECHO'
#!/usr/bin/env bash
# $1 = fixture root, $2 = the literal that must not appear in the gate's output.
set -euo pipefail
output=""
output="$(bash "${1}/scripts/check-secret-leak.sh" 2>&1)" || true

if [[ "$output" == *"$2"* ]]; then
  printf 'the refusal echoed the matched credential back into its own output\n' >&2
  exit 1
fi
printf 'refusal named the category and not the credential\n'
NOECHO

# ---------------------------------------------------------------------------
# THE SHIPPED SHAPE PASSES — including the operator guidance that names a
# private-range subnet, a docker-bridge range and a loopback address. This case
# is the mechanical record of DECISIONS.md entry 15's refusal to gate on IP
# literals: a check that blocked them would block every release that explains
# subnet configuration, which is most of them.
# ---------------------------------------------------------------------------
root="$(make_fixture clean)"
run_case 'clean: a release body carrying private-range and loopback addresses passes' \
  0 "$root" 'OK'
run_case 'clean: the OK line names how many files were scanned' 0 "$root" '4 files'

# ---------------------------------------------------------------------------
# EVERY CATEGORY, IN THE VENDORED RELEASE BODY. One case per row of the shared
# table, so a row added to the library without a test here shows up as an
# untested row rather than as coverage.
# ---------------------------------------------------------------------------
index=0
for (( index = 0; index < ${#SECRET_VALUES[@]}; index++ )); do
  root="$(make_fixture "body_secret_${index}")"
  printf 'The fleet is live.\nleftover: %s\n' "${SECRET_VALUES[index]}" \
    > "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"
  run_case "category: ${SECRET_NAMES[index]} in the vendored Release body fails" \
    1 "$root" "${SECRET_LABELS[index]}"
  run_case "category: the refusal for ${SECRET_NAMES[index]} names the file it was in" \
    1 "$root" "$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"
  assert_case "privacy: the refusal for ${SECRET_NAMES[index]} never echoes the match" \
    0 'refusal named the category and not the credential' \
    bash "$NO_ECHO_CHECK" "$root" "${SECRET_VALUES[index]}"
done

# ---------------------------------------------------------------------------
# EVERY SCANNED FILE, one credential each. The contract is the file that had NO
# content check at all before this gate existed, and its documentation.* fields
# are free prose, so it gets the same treatment as the body.
# ---------------------------------------------------------------------------
root="$(make_fixture contract_secret)"
printf '{\n  "documentation": {\n    "purpose": "deploy with %s"\n  }\n}\n' \
  "${SECRET_VALUES[0]}" \
  > "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_CONTRACT_NAME")"
run_case 'file: a credential in the vendored contract prose fails' \
  1 "$root" 'an AWS access-key ID'
assert_case 'file: the contract refusal never echoes the matched text' \
  0 'refusal named the category and not the credential' \
  bash "$NO_ECHO_CHECK" "$root" "${SECRET_VALUES[0]}"

# The manifest. A hand edit that changed BOTH the listing and the vendored copy
# satisfies check-release-notes-drift.sh, which compares the two against each
# other — this gate is what closes that route.
root="$(make_fixture manifest_secret)"
printf 'releaseNotes: >-\n  token %s\n' "${SECRET_VALUES[1]}" \
  >> "${root}/${APP_ID}/umbrel-app.yml"
run_case 'file: a credential in the app manifest fails' 1 "$root" 'a GitHub token'

# The compose file, which is rewritten by the same bump and ships to the box.
root="$(make_fixture compose_secret)"
printf '    environment:\n      KEY: %s\n' "${SECRET_VALUES[4]}" \
  >> "${root}/${APP_ID}/docker-compose.yml"
run_case 'file: a credential in the compose file fails' 1 "$root" 'an sk- style API key'

# A file nobody expected, at the vendored root rather than inside a version
# directory. The walk is recursive and takes every regular file, so a leftover
# hand-written note is scanned like anything else.
root="$(make_fixture stray_vendored_file)"
printf 'old notes: %s\n' "${SECRET_VALUES[3]}" \
  > "${root}/${VENDOR_REL_DIR}/notes-old.txt"
run_case 'file: a credential in a stray file under the vendored root fails' \
  1 "$root" 'a PEM private-key header'

# ---------------------------------------------------------------------------
# FAIL-CLOSED. A scan that quietly covered nothing would be worse than no scan,
# because it would look like coverage.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_manifest)"
rm -f "${root}/${APP_ID}/umbrel-app.yml"
run_case 'fail-closed: a missing manifest fails' 1 "$root" 'app manifest not found'

root="$(make_fixture missing_compose)"
rm -f "${root}/${APP_ID}/docker-compose.yml"
run_case 'fail-closed: a missing compose file fails' 1 "$root" 'compose file not found'

root="$(make_fixture missing_vendor_root)"
rm -rf "${root:?}/${VENDOR_REL_DIR}"
run_case 'fail-closed: an absent vendored root fails' \
  1 "$root" 'vendored upstream directory not found'

root="$(make_fixture empty_vendor_root)"
rm -rf "${root:?}/$(vendor_rel_path "$PINNED")"
run_case 'fail-closed: a vendored root with no files in it fails' \
  1 "$root" 'no vendored files'

# A file the scan cannot read is not a file it can clear. grep answers 2 rather
# than 1 here, and treating that as "no match" is exactly how a scanner reports
# a file it never opened as clean.
root="$(make_fixture unreadable_file)"
chmod 000 "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"
run_case 'fail-closed: a file the scan cannot read fails' 1 "$root" 'could not scan'
chmod 644 "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"

# ---------------------------------------------------------------------------
# NO FALSE BLOCKS. Prose that merely resembles a credential prefix must pass:
# a gate that cried wolf on ordinary release notes would be turned off.
# ---------------------------------------------------------------------------
root="$(make_fixture near_miss_prose)"
printf '%s\n' 'Miner Fleet 0.3.0

The task-oriented dashboard now shows firmware. See the getting-started guide at
https://example.invalid/docs/getting-started-with-miner-fleet-and-your-boards.

Boards whose id begins AKIA are displayed unchanged; the sk- prefix in a model
name is not special.' > "${root}/$(vendor_rel_path "$PINNED" "$VENDOR_NOTES_NAME")"
run_case 'no-false-block: prose containing bare prefixes and a long URL passes' \
  0 "$root" 'OK'

report_summary
