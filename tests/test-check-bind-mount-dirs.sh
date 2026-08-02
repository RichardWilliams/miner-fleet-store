#!/usr/bin/env bash
#
# Tests for scripts/check-bind-mount-dirs.sh.
#
# Every case builds its own fixture tree under a scratch dir and runs the real
# script against it — no case reads the repo's actual compose file or app
# directory, so the suite does not pass or fail because of whatever state this
# repo happens to be in (codespace docs/testing-standards.md § 4, hermetic
# fixtures).
#
# The script resolves its repo root from its own location, so each fixture is a
# complete miniature repo: `scripts/check-bind-mount-dirs.sh` plus the app
# directory beside it.
#
# Fixture compose bodies are double-quoted with the token written `\${APP_DATA_DIR}`
# — the backslash keeps bash from expanding it, so what lands in the fixture is
# the literal text the script greps for.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-bind-mount-dirs.sh"
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

# Build a fixture repo. $1 = fixture name, $2 = the whole compose file body.
# Returns the fixture root on stdout. Directories the case wants present are
# created by the case itself, so "declared but not shipped" is the default and
# has to be satisfied deliberately.
make_fixture() {
  local name="$1" compose_body="$2"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts" "${root}/${APP_ID}"
  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-bind-mount-dirs.sh"
  chmod +x "${root}/scripts/check-bind-mount-dirs.sh"
  printf '%s\n' "$compose_body" > "${root}/${APP_ID}/docker-compose.yml"
  printf '%s' "$root"
}

# $1 = case description, $2 = expected exit (0 pass / 1 fail),
# $3 = fixture root, $4 = substring expected in output (empty to skip)
assert_case() {
  local desc="$1" expected="$2" root="$3" expect_substr="$4"
  local out="" rc=0
  out="$(bash "${root}/scripts/check-bind-mount-dirs.sh" 2>&1)" || rc=$?

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

readonly COMPOSE_SIMPLE="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data"

# ---------------------------------------------------------------------------
# Case 1 — SHIPPED. The declared directory exists in the app template; the
# check passes and names what it verified.
# ---------------------------------------------------------------------------
root="$(make_fixture shipped "$COMPOSE_SIMPLE")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'shipped: declared data/ present passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/data"

# ---------------------------------------------------------------------------
# Case 2 — NOT SHIPPED. This is issue #8 itself: the compose declares
# ${APP_DATA_DIR}/data and the app template ships no data/ directory, so Docker
# creates the bind-mount source root:root on a fresh install and the hardened
# container cannot write into it. Must fail, and must name both the compose line
# and the repo path so the diagnosis is immediate.
# ---------------------------------------------------------------------------
root="$(make_fixture not_shipped "$COMPOSE_SIMPLE")"
assert_case 'not shipped: declared data/ missing fails' 1 "$root" "${APP_ID}/data does not exist in this repo"

root="$(make_fixture not_shipped_reason "$COMPOSE_SIMPLE")"
assert_case 'not shipped: failure names the root:root consequence' 1 "$root" 'root:root at compose up'

# ---------------------------------------------------------------------------
# Case 3 — MISSING COMPOSE. The first thing the script checks, before any
# parsing.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_compose "$COMPOSE_SIMPLE")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'missing: absent compose file fails closed' 1 "$root" 'compose file not found'

# ---------------------------------------------------------------------------
# Case 4 — NO APP-DATA REFERENCE AT ALL. Fail-closed on input the check cannot
# check: a compose declaring no ${APP_DATA_DIR} path means the file changed
# shape or the script is reading the wrong thing. Reporting OK here would report
# safety it never established.
# ---------------------------------------------------------------------------
root="$(make_fixture no_app_data 'services:
  server:
    image: example/app:1.0.0
    restart: on-failure')"
assert_case "no reference: compose with no \${APP_DATA_DIR} line fails closed" 1 "$root" 'declares no app-data path'

# ---------------------------------------------------------------------------
# Case 5 — NESTED SUBPATH, both directions. A multi-segment host subpath is a
# legal mount and must be resolved segment-for-segment, not collapsed to its
# first segment: `a/b` present must pass, and `a` present with `a/b` absent must
# still fail. A check that only looked at the first segment would pass the
# second case wrongly.
# ---------------------------------------------------------------------------
readonly COMPOSE_NESTED="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/state/db:/x"

root="$(make_fixture nested_present "$COMPOSE_NESTED")"
mkdir -p "${root}/${APP_ID}/state/db"
assert_case 'nested: present a/b passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/state/db"

root="$(make_fixture nested_missing "$COMPOSE_NESTED")"
mkdir -p "${root}/${APP_ID}/state"
assert_case 'nested: parent present but a/b missing still fails' 1 "$root" "${APP_ID}/state/db does not exist"

# ---------------------------------------------------------------------------
# Case 6 — EXISTS BUT IS A FILE. A bind-mount source must be a directory in the
# template; umbreld copies the template verbatim, so a file here is what the box
# would get. Distinct message from the missing case — the two need different
# fixes and a shared message would hide which one is in play.
# ---------------------------------------------------------------------------
root="$(make_fixture data_is_a_file "$COMPOSE_SIMPLE")"
printf 'not a directory\n' > "${root}/${APP_ID}/data"
assert_case 'wrong type: path exists as a file fails' 1 "$root" 'is not a directory'

# ---------------------------------------------------------------------------
# Case 7 — UNRECOGNISED SHAPE. A long-form `type: bind` volume declares a
# bind-mount source in a shape this check does not parse. Silently passing over
# it is precisely the case where a real missing directory would be hidden, so an
# unclassifiable ${APP_DATA_DIR} line is a failure that names the line.
# ---------------------------------------------------------------------------
root="$(make_fixture longform_bind "services:
  server:
    image: example/app:1.0.0
    volumes:
      - type: bind
        source: \${APP_DATA_DIR}/data
        target: /data")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'unrecognised: long-form type/source volume fails closed' 1 "$root" "unrecognised \${APP_DATA_DIR} line shape"

# ---------------------------------------------------------------------------
# Case 8 — TRAILING COMMENT on the volume line. Valid YAML, and the compose file
# in this repo comments heavily around exactly this line, so a pattern that
# rejected it would block a correct edit. A gate that refuses valid work fails in
# the direction that looks safe.
# ---------------------------------------------------------------------------
root="$(make_fixture trailing_comment "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data  # survives updates, removed on uninstall")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'variant: trailing comment on the volume line passes' 0 "$root" 'OK'

# ---------------------------------------------------------------------------
# Case 9 — TWO VOLUMES, ONE SHIPPED. Every declared source is asserted, not just
# the first. A check that stopped at its first satisfied mount would pass this.
# ---------------------------------------------------------------------------
readonly COMPOSE_TWO_VOLUMES="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data
      - \${APP_DATA_DIR}/cache:/cache"

root="$(make_fixture two_volumes_one_shipped "$COMPOSE_TWO_VOLUMES")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'two volumes: second declared dir missing fails' 1 "$root" "${APP_ID}/cache does not exist"

root="$(make_fixture two_volumes_both_shipped "$COMPOSE_TWO_VOLUMES")"
mkdir -p "${root}/${APP_ID}/data" "${root}/${APP_ID}/cache"
assert_case 'two volumes: both declared dirs present passes' 0 "$root" "${APP_ID}/data ${APP_ID}/cache"

# ---------------------------------------------------------------------------
# Case 10 — env_file LONG-FORM PATH ENTRY. `- path: ${APP_DATA_DIR}/…` names a
# FILE Compose reads, not a bind-mount source Docker creates, so it is
# recognised and deliberately excluded from the directory assertion. The
# exclusion has to be proven rather than assumed: without this case, an
# implementation that happened to fall through on the line would be
# indistinguishable from one that classified it on purpose.
# ---------------------------------------------------------------------------
root="$(make_fixture env_file_entry "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'env_file: long-form path entry beside a satisfied volume passes' 0 "$root" 'OK'

# The exclusion must be exactly that — an exclusion, not a second way to satisfy
# the check. An env_file path alone declares no bind-mount source, so a compose
# carrying only one must still fail closed.
root="$(make_fixture env_file_only "services:
  server:
    image: example/app:1.0.0
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'env_file: an env_file path alone declares no volume and fails closed' 1 "$root" "no short-form \${APP_DATA_DIR} volume entry found"

# ---------------------------------------------------------------------------
# ADVERSARIAL comment collisions.
#
# The real compose file quotes ${APP_DATA_DIR} four times in PROSE, once in a
# full `${APP_DATA_DIR}/data:/data` shape (the vaultwarden precedent it cites).
# Both directions of that collision are live and are pinned here: a comment must
# not be read as a declaration, and it must not be read as an unclassifiable
# line either. These assert on the extracted path in the message, not just the
# exit code — a case checking only the exit code passes while the check is
# reading the wrong line.
# ---------------------------------------------------------------------------
root="$(make_fixture adversarial_comment_masks "services:
  server:
    image: example/app:1.0.0
    # The shipped-app precedent is vaultwarden's \${APP_DATA_DIR}/prose:/prose.
    volumes:
      - \${APP_DATA_DIR}/data:/data")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'adversarial: a volume-shaped mention in a comment is not a declaration' 0 "$root" "shipped: ${APP_ID}/data"

# The mirror direction: a comment must not SATISFY the check either. A compose
# whose only volume-shaped ${APP_DATA_DIR} text sits inside prose declares no
# mount, and must fail closed rather than pass on a directory nobody declared.
root="$(make_fixture adversarial_comment_only "services:
  server:
    image: example/app:1.0.0
    # Precedent for a future release: \${APP_DATA_DIR}/data:/data.
    restart: on-failure")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'adversarial: a volume named only in a comment does not satisfy the check' 1 "$root" 'declares no app-data path'

# The same collision class on the volume line ITSELF, which whole-line comment
# handling cannot reach: a TRAILING comment carrying a second
# `${APP_DATA_DIR}/…:/…` token. This is the case that failed twice on the
# sibling check — an unanchored greedy strip reads the value out of the LAST
# occurrence, which is the comment, instead of the one the pattern anchored on.
# Both directions are pinned, and both assert on the extracted path rather than
# the exit code alone: the first direction alone passes green under a greedy
# extraction whenever the commented path happens to exist.
readonly COMPOSE_TRAILING_COLLISION="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data  # was \${APP_DATA_DIR}/legacy:/data before the rename"

root="$(make_fixture adversarial_trailing_false_reject "$COMPOSE_TRAILING_COLLISION")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'adversarial: a second path in a trailing comment must NOT cause a false reject' 0 "$root" "shipped: ${APP_ID}/data"

root="$(make_fixture adversarial_trailing_masks "$COMPOSE_TRAILING_COLLISION")"
mkdir -p "${root}/${APP_ID}/legacy"
assert_case 'adversarial: a second path in a trailing comment must NOT mask a missing dir' 1 "$root" "${APP_ID}/data does not exist"

# ---------------------------------------------------------------------------
# MALFORMED SUBPATH. `${APP_DATA_DIR}/:/data` matches the volume shape but
# extracts an empty host subpath, which resolves to the app directory itself
# rather than a subdirectory of it. An extraction the check cannot use is a
# failure, not a silently-skipped line.
# ---------------------------------------------------------------------------
root="$(make_fixture empty_subpath "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/:/data")"
mkdir -p "${root}/${APP_ID}/data"
assert_case 'malformed: empty host subpath fails closed' 1 "$root" 'unusable host-side subpath'

printf '\n%d passed, %d failed\n' "$passes" "$failures"
(( failures == 0 )) || exit 1
