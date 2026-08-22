#!/usr/bin/env bash
#
# Tests for scripts/check-release-notes-drift.sh and for the folded-scalar
# round-trip it shares with scripts/release.sh.
#
# Every case builds its own miniature repo under the harness scratch dir — the
# gate script, the libraries it sources, an app manifest and a vendored upstream
# body — and runs the real script against it (codespace
# docs/testing-standards.md § 4.1, hermetic fixtures). No case reads this repo's
# actual manifest, and no case makes a network call of any kind: the gate is a
# textual comparison against a committed artefact by construction, so there is
# nothing to stub.
#
# The round-trip cases are the reason this suite carries more than fail-closed
# coverage. A `>-` folded scalar is lossy, so the interesting failure is not
# only "drift slipped through" but also "a byte-perfect body was rejected". Both
# directions are pinned here.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-release-notes-drift.sh"
readonly COMMON_LIB="${repo_root}/scripts/lib/check-common.sh"
readonly CONTEXT_LIB="${repo_root}/scripts/lib/repo-context.sh"
readonly PARSER_LIB="${repo_root}/scripts/lib/manifest_data.py"

for required in "$SCRIPT_UNDER_TEST" "$COMMON_LIB" "$CONTEXT_LIB" "$PARSER_LIB"; do
  [[ -f "$required" ]] || {
    printf 'FATAL: file under test not found at %s\n' "$required" >&2
    exit 1
  }
done

# The app id, the vendored-artefact directory and the releaseNotes block indent
# come from the one place that declares them, exactly as tests/test-release.sh
# already does. The indent is read rather than retyped for single-source-of-truth
# reasons only, and NOT as a guard against a stale value: a folded scalar's block
# indent is taken from its own content and stripped on parse, so every assertion
# below yields the same string at any indent >= 1 and a retyped literal here
# would mask nothing. scripts/lib/repo-context.sh states that in full beside the
# declaration.
source "$CONTEXT_LIB"

# The scratch dir, its single cleanup trap, the counters, assert_case and the
# summary line are shared with the sibling suites.
harness="${script_dir}/lib/bash-test-harness.sh"
[[ -f "$harness" ]] || {
  printf 'FATAL: shared test harness not found at %s\n' "$harness" >&2
  exit 1
}
source "$harness"

# A standalone comparison so a round-trip expectation can be asserted through
# the harness's exit-code + substring contract without quoting a multi-line
# value into a `bash -c` string.
readonly ROUND_TRIP_COMPARE="${scratch}/compare-round-trip.sh"
cat > "$ROUND_TRIP_COMPARE" <<'COMPARE'
#!/usr/bin/env bash
# $1 = parser module, $2 = body file, $3 = expected-value file, $4 = block indent
set -euo pipefail
actual="$(python3 "$1" round-trip "$2" "$4")"
expected="$(cat "$3")"
if [[ "$actual" != "$expected" ]]; then
  printf 'round-trip mismatch\n--- actual ---\n%s\n--- expected ---\n%s\n' "$actual" "$expected" >&2
  exit 1
fi
printf 'round-trip matches\n'
COMPARE

body_counter=0

# $1 = case description, $2 = body, $3 = expected parsed value.
round_trip_case() {
  local desc="$1" body="$2" expected="$3"
  body_counter=$(( body_counter + 1 ))
  local body_file="${scratch}/rt-body-${body_counter}.txt"
  local expected_file="${scratch}/rt-expected-${body_counter}.txt"
  printf '%s\n' "$body" > "$body_file"
  printf '%s\n' "$expected" > "$expected_file"
  assert_case "$desc" 0 'round-trip matches' \
    bash "$ROUND_TRIP_COMPARE" "$PARSER_LIB" "$body_file" "$expected_file" \
      "$NOTES_BLOCK_INDENT"
}

# $1 = case description, $2 = body, $3 = expected refusal substring.
#
# The refusal counterpart of `round_trip_case`: a body the emitter cannot
# represent faithfully must be REFUSED by name, not emitted into a manifest.
refused_body_case() {
  local desc="$1" body="$2" expected="$3"
  body_counter=$(( body_counter + 1 ))
  local body_file="${scratch}/rt-body-${body_counter}.txt"
  printf '%s\n' "$body" > "$body_file"
  assert_case "$desc" 1 "$expected" \
    python3 "$PARSER_LIB" round-trip "$body_file" "$NOTES_BLOCK_INDENT"
}

# Build a miniature repo. $1 = fixture name. Returns the fixture root.
make_fixture() {
  local name="$1"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}" "${root}/${VENDOR_REL_DIR}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-release-notes-drift.sh"
  chmod +x "${root}/scripts/check-release-notes-drift.sh"
  cp "$COMMON_LIB" "${root}/scripts/lib/check-common.sh"
  cp "$CONTEXT_LIB" "${root}/scripts/lib/repo-context.sh"
  cp "$PARSER_LIB" "${root}/scripts/lib/manifest_data.py"
  printf '%s' "$root"
}

# Write a manifest whose releaseNotes block is produced by the REAL emitter, so
# the passing cases are correct by construction rather than by hand-transcribed
# indentation. $1 = root, $2 = version, $3 = body file.
write_emitted_manifest() {
  local root="$1" version="$2" body_file="$3"
  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
version: "${version}"
port: 3007
releaseNotes: >-
  replaced below by the real emitter
developer: Pipfox
EOF
  python3 "${root}/scripts/lib/manifest_data.py" set-block \
    "${root}/${APP_ID}/umbrel-app.yml" releaseNotes "$body_file" \
    "$NOTES_BLOCK_INDENT"
}

# $1 = root, $2 = vendored directory name, $3 = body text.
write_vendored_body() {
  local root="$1" dir_name="$2" body="$3"
  mkdir -p "${root}/${VENDOR_REL_DIR}/${dir_name}"
  printf '%s\n' "$body" > "${root}/${VENDOR_REL_DIR}/${dir_name}/release-notes.txt"
}

# $1 = case description, $2 = expected exit, $3 = fixture root, $4 = substring.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-release-notes-drift.sh"
}

# ---------------------------------------------------------------------------
# The emitter rule, asserted directly. These three cases ARE the round-trip
# contract: a blank-line paragraph break survives verbatim, soft-wrapped lines
# inside one paragraph fold to single spaces, and more-indented bullet lines
# keep both their line breaks and their extra indentation. Every gate assertion
# below rests on them.
# ---------------------------------------------------------------------------
round_trip_case 'emitter: a blank-line paragraph break survives the round trip' \
  'First paragraph.

Second paragraph.' \
  'First paragraph.

Second paragraph.'

round_trip_case 'emitter: soft-wrapped lines inside one paragraph fold to single spaces' \
  'Line one.
Line two.' \
  'Line one. Line two.'

round_trip_case 'emitter: more-indented bullet lines keep their breaks and their indent' \
  'Two fixes:

  - the first one, which wraps
    onto a second line
  - the second one' \
  'Two fixes:

  - the first one, which wraps
    onto a second line
  - the second one'

# A body carrying colons, quotation marks and a CIDR-shaped value survives
# unchanged — the substitution-into-YAML defect this spelling exists to prevent.
round_trip_case 'emitter: colons and quotation marks in the body survive verbatim' \
  'Fleet: live now.

One setup step: create "config.env" and set MINER_FLEET_SUBNETS=10.0.0.0/24.

  - discovery
  - telemetry' \
  'Fleet: live now.

One setup step: create "config.env" and set MINER_FLEET_SUBNETS=10.0.0.0/24.

  - discovery
  - telemetry'

# A body whose FIRST line is blank is refused rather than emitted. The emitter
# decides a blank run's width from the line before the run, so a run starting at
# the first line would read the line before position 0 — the LAST line — and
# size the run against an unrelated neighbour. The observed result was a leading
# blank line silently becoming two, in a value copied verbatim from upstream and
# never authored here. Both this gate and scripts/release.sh call the same
# emitter, so nothing downstream would have caught it: the comparison would have
# been wrong against equally wrong and passed.
refused_body_case 'emitter: a blank first line is refused, not silently doubled' \
  '
Miner Fleet 0.4.0

A change.' \
  "first line is blank"

# ---------------------------------------------------------------------------
# THE FALSE-BLOCK CASE. A byte-perfect body, emitted as a `>-` scalar, must
# PASS. A raw-string comparison fails here on correct input — the whole reason
# the gate compares parsed against emitted-then-parsed.
# ---------------------------------------------------------------------------
readonly FOLDING_BODY='Line one.
Line two.

Paragraph two.

  - bullet one
  - bullet two'

root="$(make_fixture folding_round_trip)"
printf '%s\n' "$FOLDING_BODY" > "${scratch}/folding-body.txt"
write_emitted_manifest "$root" '0.3.0' "${scratch}/folding-body.txt"
write_vendored_body "$root" 'v0.3.0' "$FOLDING_BODY"
run_case 'round-trip: a byte-perfect body emitted as a folded scalar passes' 0 "$root" 'OK'

# The same shape with a real-looking body: soft-wrapped prose paragraphs plus an
# indented bullet block, which is how every shipped first-party manifest and
# this repo's own listing are spelled.
readonly REALISTIC_BODY='Miner Fleet 0.3.0

Firmware versions are now visible across the fleet. Each board shows the
firmware it is running alongside the latest release published for its model,
with an indicator when an update is available.

Two fixes to how the app watches your fleet:

  - Warnings now fire for boards found by network discovery. Samples taken on
    the discovery path were stored without being checked against the rules.

  - The app now runs a single polling loop.'

root="$(make_fixture realistic_body)"
printf '%s\n' "$REALISTIC_BODY" > "${scratch}/realistic-body.txt"
write_emitted_manifest "$root" '0.3.0' "${scratch}/realistic-body.txt"
write_vendored_body "$root" 'v0.3.0' "$REALISTIC_BODY"
run_case 'round-trip: a soft-wrapped body with a bullet block passes' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# DRIFT. The real-world failure: the listing carries text the upstream Release
# does not. Must fail, and must name BOTH values so the diagnosis is immediate.
# ---------------------------------------------------------------------------
root="$(make_fixture drift)"
printf '%s\n' 'The fleet is live.' > "${scratch}/drift-manifest-body.txt"
write_emitted_manifest "$root" '0.3.0' "${scratch}/drift-manifest-body.txt"
write_vendored_body "$root" 'v0.3.0' 'Something else entirely.'
run_case 'drift: a listing that differs from the Release body fails' 1 "$root" 'The fleet is live.'
run_case 'drift: the failure names the upstream value too' 1 "$root" 'Something else entirely.'

# A body that differs only in a paragraph BREAK is still drift. Folding
# collapses whitespace, so a gate that normalised too eagerly would pass this.
root="$(make_fixture drift_paragraph_only)"
printf '%s\n' 'One.

Two.' > "${scratch}/drift-paragraph-body.txt"
write_emitted_manifest "$root" '0.3.0' "${scratch}/drift-paragraph-body.txt"
write_vendored_body "$root" 'v0.3.0' 'One.
Two.'
run_case 'drift: a body differing only in a paragraph break still fails' 1 "$root" 'release-notes drift'

# ---------------------------------------------------------------------------
# FAIL-CLOSED. Every unreadable input is a failure, never a skip.
# ---------------------------------------------------------------------------
readonly BASE_BODY='The fleet is live.'

# The manifest file is gone.
root="$(make_fixture missing_manifest)"
printf '%s\n' "$BASE_BODY" > "${scratch}/base-body.txt"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
rm -f "${root}/${APP_ID}/umbrel-app.yml"
run_case 'fail-closed: a missing manifest fails' 1 "$root" 'app manifest not found'

# `releaseNotes` is absent entirely.
root="$(make_fixture absent_release_notes)"
cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
version: "0.3.0"
port: 3007
developer: Pipfox
EOF
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
run_case "fail-closed: an absent 'releaseNotes' fails" 1 "$root" "no 'releaseNotes' found"

# `releaseNotes` appears twice. PyYAML keeps the last duplicate silently; the
# gate's parser refuses instead, because the check cannot know which copy is
# authoritative and picking one would be a guess.
root="$(make_fixture duplicate_release_notes)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
printf 'releaseNotes: >-\n  a second, contradictory copy\n' >> "${root}/${APP_ID}/umbrel-app.yml"
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
run_case "fail-closed: a duplicated 'releaseNotes' fails" 1 "$root" 'duplicate key'

# The pinned version is not a semver, so no vendored directory name follows
# from it.
root="$(make_fixture unparseable_version)"
cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
version: "not-a-version"
port: 3007
releaseNotes: >-
  ${BASE_BODY}
developer: Pipfox
EOF
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
run_case 'fail-closed: an unparseable version fails' 1 "$root" 'is not a semver'

# The vendored body — the artefact that stands in for the live Release under the
# vendor-at-bump-time policy — is missing. This is the "upstream Release
# unreachable" case: with no network at gate time, an unreachable Release is an
# absent committed copy, and it fails exactly the same way.
root="$(make_fixture missing_vendored_body)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
mkdir -p "${root}/${VENDOR_REL_DIR}/v0.3.0"
run_case 'fail-closed: a missing vendored Release body fails' 1 "$root" 'vendored release body not found'

# The vendored body exists but is empty. An empty upstream Release body is a
# hard failure, never an empty listing.
root="$(make_fixture empty_vendored_body)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
mkdir -p "${root}/${VENDOR_REL_DIR}/v0.3.0"
: > "${root}/${VENDOR_REL_DIR}/v0.3.0/release-notes.txt"
run_case 'fail-closed: an empty vendored Release body fails' 1 "$root" 'is empty'

# No vendored directory at all.
root="$(make_fixture no_vendored_directory)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
run_case 'fail-closed: no vendored directory fails' 1 "$root" 'no vendored upstream directory'

# Two vendored directories. A stale copy beside a current one could otherwise
# satisfy the gate against the wrong release, which is the staleness hole the
# version-encoded directory name exists to close.
root="$(make_fixture two_vendored_directories)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
write_vendored_body "$root" 'v0.2.0' 'the previous release'
run_case 'fail-closed: two vendored directories fail' 1 "$root" 'expected exactly one'

# One vendored directory, named for a DIFFERENT version than the manifest pins —
# a bump that forgot to re-vendor.
root="$(make_fixture stale_vendored_directory)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
write_vendored_body "$root" 'v0.2.0' "$BASE_BODY"
run_case 'fail-closed: a vendored directory naming another version fails' 1 "$root" 'but the manifest pins 0.3.0'

# The vendored root directory is gone entirely.
root="$(make_fixture no_vendor_root)"
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
rmdir "${root}/${VENDOR_REL_DIR}"
run_case 'fail-closed: an absent vendored root fails' 1 "$root" 'vendored upstream directory not found'

# ---------------------------------------------------------------------------
# ONE DECLARATION OF THE VENDORED DIRECTORY NAME. The name is COMPARED against
# what is on disk and also used to BUILD the path of the body read inside it, so
# the staleness guard only holds while both sites read the same declaration.
#
# These two cases redeclare the name in the fixture's own copy of the context
# library and require the gate to follow it end to end. A `v${version}` re-
# inlined at the comparison would refuse the redeclared directory; one re-inlined
# at the body path would look for the body under a directory that is not there.
# The second case is what stops the first from passing by ignoring the name.
# ---------------------------------------------------------------------------
root="$(make_fixture redeclared_dir_name)"
redeclare_vendor_dir_name "${root}/scripts/lib/repo-context.sh" 'rel-'
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
write_vendored_body "$root" 'rel-0.3.0' "$BASE_BODY"
run_case 'one declaration: the gate follows a redeclared vendored directory name' 0 "$root" 'OK'

root="$(make_fixture redeclared_dir_name_old_spelling)"
redeclare_vendor_dir_name "${root}/scripts/lib/repo-context.sh" 'rel-'
write_emitted_manifest "$root" '0.3.0' "${scratch}/base-body.txt"
write_vendored_body "$root" 'v0.3.0' "$BASE_BODY"
run_case 'one declaration: a directory named the old way no longer satisfies the gate' \
  1 "$root" 'but the manifest pins 0.3.0'

report_summary
