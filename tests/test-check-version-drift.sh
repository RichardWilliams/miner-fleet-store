#!/usr/bin/env bash
#
# Tests for scripts/check-version-drift.sh.
#
# Every case builds its own fixture tree under a scratch dir and runs the real
# script against it — no case reads the repo's actual manifests, so the suite
# does not pass or fail because of whatever version this repo happens to be on
# (codespace docs/testing-standards.md § 4, hermetic fixtures).
#
# The script resolves its repo root from its own location, so each fixture is a
# complete miniature repo: `scripts/check-version-drift.sh` plus the app
# directory beside it.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-version-drift.sh"
readonly LIB_UNDER_TEST="${repo_root}/scripts/lib/check-common.sh"
readonly APP_ID="pipfox-miner-fleet"

[[ -f "$SCRIPT_UNDER_TEST" ]] || {
  printf 'FATAL: script under test not found at %s\n' "$SCRIPT_UNDER_TEST" >&2
  exit 1
}
[[ -f "$LIB_UNDER_TEST" ]] || {
  printf 'FATAL: shared check lib not found at %s\n' "$LIB_UNDER_TEST" >&2
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

# Build a fixture repo. $1 = fixture name, $2 = manifest version line,
# $3 = compose image line. Returns the fixture root on stdout.
make_fixture() {
  local name="$1" version_line="$2" image_line="$3"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-version-drift.sh"
  chmod +x "${root}/scripts/check-version-drift.sh"
  cp "$LIB_UNDER_TEST" "${root}/scripts/lib/check-common.sh"

  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
${version_line}
port: 3007
EOF

  cat > "${root}/${APP_ID}/docker-compose.yml" <<EOF
services:
  app_proxy:
    environment:
      APP_HOST: ${APP_ID}_server_1
      APP_PORT: 3000

  server:
${image_line}
    restart: on-failure
EOF

  printf '%s' "$root"
}

# Run the fixture's copy of the script. $1 = case description, $2 = expected
# exit, $3 = fixture root, $4 = substring expected in the output.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-version-drift.sh"
}

readonly GOOD_IMAGE='    image: ghcr.io/richardwilliams/miner-fleet:0.1.0@sha256:da0e81a0f568255bd6dac6f12274c9aec88661bba9a49057cfb57b5974e74c01'

# ---------------------------------------------------------------------------
# Case 1 — MATCH. Manifest and compose agree; the check passes.
# ---------------------------------------------------------------------------
root="$(make_fixture match 'version: "0.1.0"' "$GOOD_IMAGE")"
run_case 'match: manifest 0.1.0 == compose 0.1.0 passes' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# Cases 1a-1d — LEGITIMATE VARIANTS must PASS.
#
# These exist because the first version of this suite tested only the
# fail-closed direction. Every case asserted "bad input is rejected" and none
# asserted "good input is accepted", so a pattern that was too STRICT passed the
# whole suite: single-quoted values and trailing comments — both valid YAML for
# these fields — were rejected as malformed, which would have blocked a correct
# release edit. A gate that refuses valid work fails in the direction that looks
# safe, which is why it survived review until a reviewer ran the variants by
# hand. Asymmetric coverage is the defect these cases close.
# ---------------------------------------------------------------------------
root="$(make_fixture variant_single_quote "version: '0.1.0'" "$GOOD_IMAGE")"
run_case 'variant: single-quoted version passes' 0 "$root" 'OK'

root="$(make_fixture variant_unquoted 'version: 0.1.0' "$GOOD_IMAGE")"
run_case 'variant: unquoted version passes' 0 "$root" 'OK'

root="$(make_fixture variant_manifest_comment 'version: "0.1.0"  # bumped by the release procedure' "$GOOD_IMAGE")"
run_case 'variant: trailing comment on version passes' 0 "$root" 'OK'

root="$(make_fixture variant_compose_comment 'version: "0.1.0"' "${GOOD_IMAGE}  # index digest, not per-platform")"
run_case 'variant: trailing comment on image passes' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# ADVERSARIAL comment collisions.
#
# The inert comment above cannot catch the real bug, because its text shares no
# substring with the image name. The extraction was previously an unanchored
# `s|^.*/miner-fleet:||`, so a comment containing a SECOND `/miner-fleet:X.Y.Z`
# token made sed strip through the LAST occurrence and read the version out of
# the comment. Both directions were live and are pinned here.
#
# These assert on the extracted VERSION in the message, not just the exit code:
# case (a) passed its exit-code check even while broken, because it reported
# agreement on the comment's version rather than the real pin.
# ---------------------------------------------------------------------------
root="$(make_fixture adversarial_masks_drift 'version: "0.2.0"' "${GOOD_IMAGE}  # bumping to richardwilliams/miner-fleet:0.2.0")"
run_case 'adversarial: comment naming the manifest version must NOT mask real drift' 1 "$root" "pins image tag '0.1.0'"

root="$(make_fixture adversarial_false_reject 'version: "0.1.0"' "${GOOD_IMAGE}  # previously pinned richardwilliams/miner-fleet:0.0.9")"
run_case 'adversarial: comment naming an older version must NOT cause a false reject' 0 "$root" 'agree on 0.1.0'

# The same collision class, applied to the MANIFEST side. Its extraction is
# anchored and therefore safe by construction, but that was equally true of the
# compose side by hand-tracing — right up until it wasn't. The lesson is
# symmetric, so the coverage is too: a manual proof that a second occurrence
# cannot be picked up is exactly the proof that failed twice already.
root="$(make_fixture adversarial_manifest_comment 'version: "0.1.0"  # was version: 0.0.9 before the bump' "$GOOD_IMAGE")"
run_case 'adversarial: comment naming another version on the version line does not shift extraction' 0 "$root" 'agree on 0.1.0'

root="$(make_fixture adversarial_manifest_drift 'version: "0.2.0"  # matches image tag 0.1.0' "$GOOD_IMAGE")"
run_case 'adversarial: comment on the version line must NOT mask real drift' 1 "$root" "declares '0.2.0'"

# The variants must still DETECT drift — a pattern loosened until it matches
# anything would pass the four cases above while proving nothing. Single-quoted
# and drifted must fail.
root="$(make_fixture variant_quote_drift "version: '0.2.0'" "$GOOD_IMAGE")"
run_case 'variant: single-quoted 0.2.0 vs compose 0.1.0 still fails' 1 "$root" 'version drift'

# ---------------------------------------------------------------------------
# Case 2 — DRIFT. This is the real-world failure: a release PR bumps the
# manifest and forgets the compose pin. Umbrel would display 0.2.0 while the box
# runs 0.1.0. Must fail, and must name both values so the diagnosis is immediate.
# ---------------------------------------------------------------------------
root="$(make_fixture drift 'version: "0.2.0"' "$GOOD_IMAGE")"
run_case 'drift: manifest 0.2.0 vs compose 0.1.0 fails' 1 "$root" 'version drift'

# ---------------------------------------------------------------------------
# Case 3 — MALFORMED. Fail-closed: an image line the pattern cannot parse is a
# failure, not a skip. `latest` is the canonical malformed case — it is banned by
# DECISIONS.md entry 3 and carries no semver to compare against, so a check that
# skipped here would wave through exactly the reference the decision forbids.
# ---------------------------------------------------------------------------
root="$(make_fixture malformed_image 'version: "0.1.0"' '    image: ghcr.io/richardwilliams/miner-fleet:latest')"
run_case 'malformed: unpinned :latest image fails closed' 1 "$root" 'well-formed pinned'

# Malformed, second shape — the manifest field absent entirely. Covers the other
# half of fail-closed: an unreadable input on the manifest side, not the compose
# side.
root="$(make_fixture malformed_manifest 'name_only: nothing' "$GOOD_IMAGE")"
run_case "malformed: absent manifest 'version:' fails closed" 1 "$root" "well-formed 'version:'"

# Malformed, third shape — a digest-less bare tag. Reproducible-pinning is the
# point of DECISIONS entry 3; a bare tag parses as a semver but is not a pin, so
# the pattern must reject it rather than compare it successfully.
root="$(make_fixture malformed_no_digest 'version: "0.1.0"' '    image: ghcr.io/richardwilliams/miner-fleet:0.1.0')"
run_case 'malformed: tag without digest fails closed' 1 "$root" 'well-formed pinned'

# Malformed, fourth shape — mismatched quote characters. Valid-looking but not
# valid YAML. Accepting it would contradict the fail-closed contract, and the
# earlier `['\"]?...['\"]?` form did exactly that by matching the opening and
# closing quote independently.
root="$(make_fixture malformed_mismatched_quotes "version: '0.1.0\"" "$GOOD_IMAGE")"
run_case 'malformed: mismatched quote characters fail closed' 1 "$root" "well-formed 'version:'"

# ---------------------------------------------------------------------------
# Falsifiability guard — a duplicated field is ambiguous, and picking one copy
# would be a guess. Without this the check would silently read the first match.
# ---------------------------------------------------------------------------
root="$(make_fixture duplicate_version 'version: "0.1.0"' "$GOOD_IMAGE")"
printf 'version: "0.9.9"\n' >> "${root}/${APP_ID}/umbrel-app.yml"
run_case 'ambiguous: two version lines fail closed' 1 "$root" 'cannot determine which is authoritative'

# `require_exactly_one` is shared by both sides, so testing it on the manifest
# alone left the compose call site unexercised. It failed closed there correctly
# — but by hand-reasoning, not by test. This makes it mechanical.
root="$(make_fixture duplicate_compose_image 'version: "0.1.0"' "$GOOD_IMAGE")"
printf '%s\n' "$GOOD_IMAGE" >> "${root}/${APP_ID}/docker-compose.yml"
run_case 'ambiguous: two image lines fail closed' 1 "$root" 'cannot determine which is authoritative'

# ---------------------------------------------------------------------------
# Missing-file guard — the first thing the script checks.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_compose 'version: "0.1.0"' "$GOOD_IMAGE")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
run_case 'missing: absent compose file fails closed' 1 "$root" 'compose file not found'

report_summary
