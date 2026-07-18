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
readonly APP_ID="pipfox-miner-fleet"

[[ -f "$SCRIPT_UNDER_TEST" ]] || {
  printf 'FATAL: script under test not found at %s\n' "$SCRIPT_UNDER_TEST" >&2
  exit 1
}

scratch=""
# ONE cleanup handler, registered once (codespace docs/coding-standards.md
# § 9.3 — a second `trap ... EXIT` at this scope would silently replace it).
cleanup() {
  [[ -n "$scratch" && -d "$scratch" ]] && rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

scratch="$(mktemp -d)"

failures=0
passes=0

# Build a fixture repo. $1 = fixture name, $2 = manifest version line,
# $3 = compose image line. Returns the fixture root on stdout.
make_fixture() {
  local name="$1" version_line="$2" image_line="$3"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts" "${root}/${APP_ID}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-version-drift.sh"
  chmod +x "${root}/scripts/check-version-drift.sh"

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

# $1 = case description, $2 = expected exit (0 pass / 1 fail),
# $3 = fixture root, $4 = substring expected in output (empty to skip)
assert_case() {
  local desc="$1" expected="$2" root="$3" expect_substr="$4"
  local out="" rc=0
  out="$(bash "${root}/scripts/check-version-drift.sh" 2>&1)" || rc=$?

  if (( rc != expected )); then
    printf 'FAIL: %s — expected exit %d, got %d\n' "$desc" "$expected" "$rc" >&2
    printf '      output: %s\n' "$out" >&2
    failures=$(( failures + 1 ))
    return
  fi

  if [[ -n "$expect_substr" && "$out" != *"$expect_substr"* ]]; then
    printf 'FAIL: %s — exit %d correct, but output did not contain %q\n' "$desc" "$rc" "$expect_substr" >&2
    printf '      output: %s\n' "$out" >&2
    failures=$(( failures + 1 ))
    return
  fi

  printf 'PASS: %s\n' "$desc"
  passes=$(( passes + 1 ))
}

readonly GOOD_IMAGE='    image: ghcr.io/richardwilliams/miner-fleet:0.1.0@sha256:da0e81a0f568255bd6dac6f12274c9aec88661bba9a49057cfb57b5974e74c01'

# ---------------------------------------------------------------------------
# Case 1 — MATCH. Manifest and compose agree; the check passes.
# ---------------------------------------------------------------------------
root="$(make_fixture match 'version: "0.1.0"' "$GOOD_IMAGE")"
assert_case 'match: manifest 0.1.0 == compose 0.1.0 passes' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# Case 2 — DRIFT. This is the real-world failure: a release PR bumps the
# manifest and forgets the compose pin. Umbrel would display 0.2.0 while the box
# runs 0.1.0. Must fail, and must name both values so the diagnosis is immediate.
# ---------------------------------------------------------------------------
root="$(make_fixture drift 'version: "0.2.0"' "$GOOD_IMAGE")"
assert_case 'drift: manifest 0.2.0 vs compose 0.1.0 fails' 1 "$root" 'version drift'

# ---------------------------------------------------------------------------
# Case 3 — MALFORMED. Fail-closed: an image line the pattern cannot parse is a
# failure, not a skip. `latest` is the canonical malformed case — it is banned by
# DECISIONS.md entry 3 and carries no semver to compare against, so a check that
# skipped here would wave through exactly the reference the decision forbids.
# ---------------------------------------------------------------------------
root="$(make_fixture malformed_image 'version: "0.1.0"' '    image: ghcr.io/richardwilliams/miner-fleet:latest')"
assert_case 'malformed: unpinned :latest image fails closed' 1 "$root" 'well-formed pinned'

# Malformed, second shape — the manifest field absent entirely. Covers the other
# half of fail-closed: an unreadable input on the manifest side, not the compose
# side.
root="$(make_fixture malformed_manifest 'name_only: nothing' "$GOOD_IMAGE")"
assert_case "malformed: absent manifest 'version:' fails closed" 1 "$root" "well-formed 'version:'"

# Malformed, third shape — a digest-less bare tag. Reproducible-pinning is the
# point of DECISIONS entry 3; a bare tag parses as a semver but is not a pin, so
# the pattern must reject it rather than compare it successfully.
root="$(make_fixture malformed_no_digest 'version: "0.1.0"' '    image: ghcr.io/richardwilliams/miner-fleet:0.1.0')"
assert_case 'malformed: tag without digest fails closed' 1 "$root" 'well-formed pinned'

# ---------------------------------------------------------------------------
# Falsifiability guard — a duplicated field is ambiguous, and picking one copy
# would be a guess. Without this the check would silently read the first match.
# ---------------------------------------------------------------------------
root="$(make_fixture duplicate_version 'version: "0.1.0"' "$GOOD_IMAGE")"
printf 'version: "0.9.9"\n' >> "${root}/${APP_ID}/umbrel-app.yml"
assert_case 'ambiguous: two version lines fail closed' 1 "$root" 'cannot determine which is authoritative'

# ---------------------------------------------------------------------------
# Missing-file guard — the first thing the script checks.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_compose 'version: "0.1.0"' "$GOOD_IMAGE")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
assert_case 'missing: absent compose file fails closed' 1 "$root" 'compose file not found'

printf '\n%d passed, %d failed\n' "$passes" "$failures"
(( failures == 0 )) || exit 1
