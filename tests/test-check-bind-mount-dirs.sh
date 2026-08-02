#!/usr/bin/env bash
#
# Tests for scripts/check-bind-mount-dirs.sh.
#
# Every case builds its own fixture tree under the harness scratch dir and runs
# the real script against it — no case reads the repo's actual compose file or
# app directory (codespace docs/testing-standards.md § 4.1, hermetic fixtures).
# The script resolves its repo root from its own location, so each fixture is a
# complete miniature repo: the script plus the app directory beside it.
#
# Fixture compose bodies are double-quoted with the token written
# `\${APP_DATA_DIR}` — the backslash keeps bash from expanding it, so what lands
# in the fixture is the literal text the script greps for.

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/check-bind-mount-dirs.sh"
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
# Returns the fixture root on stdout. Directories a case wants present are
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

# Run the fixture's copy of the script. $1 = case description, $2 = expected
# exit, $3 = fixture root, $4 = substring expected in the output.
run_case() {
  assert_case "$1" "$2" "$4" bash "${3}/scripts/check-bind-mount-dirs.sh"
}

readonly COMPOSE_SIMPLE="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data"

# SHIPPED — the declared directory exists; the check passes and names it.
root="$(make_fixture shipped "$COMPOSE_SIMPLE")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'shipped: declared data/ present passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/data"

# NOT SHIPPED — issue #8 itself. Must name both the compose line and the repo
# path, and the root:root consequence, so the diagnosis is immediate.
root="$(make_fixture not_shipped "$COMPOSE_SIMPLE")"
run_case 'not shipped: declared data/ missing fails' 1 "$root" "${APP_ID}/data does not exist in this repo"

root="$(make_fixture not_shipped_reason "$COMPOSE_SIMPLE")"
run_case 'not shipped: failure names the root:root consequence' 1 "$root" 'root:root at compose up'

# MISSING COMPOSE — the first thing the script checks, before any parsing.
root="$(make_fixture missing_compose "$COMPOSE_SIMPLE")"
rm -f "${root}/${APP_ID}/docker-compose.yml"
mkdir -p "${root}/${APP_ID}/data"
run_case 'missing: absent compose file fails closed' 1 "$root" 'compose file not found'

# NO APP-DATA REFERENCE — fail-closed on input the check cannot check.
root="$(make_fixture no_app_data 'services:
  server:
    image: example/app:1.0.0
    restart: on-failure')"
run_case "no reference: compose with no \${APP_DATA_DIR} line fails closed" 1 "$root" 'declares no app-data path'

# NESTED SUBPATH, both directions. A check that only looked at the first segment
# would wrongly pass the second case.
readonly COMPOSE_NESTED="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/state/db:/x"

root="$(make_fixture nested_present "$COMPOSE_NESTED")"
mkdir -p "${root}/${APP_ID}/state/db"
run_case 'nested: present a/b passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/state/db"

root="$(make_fixture nested_missing "$COMPOSE_NESTED")"
mkdir -p "${root}/${APP_ID}/state"
run_case 'nested: parent present but a/b missing still fails' 1 "$root" "${APP_ID}/state/db does not exist"

# EXISTS BUT IS A FILE — a distinct message from the missing case, because the
# two need different fixes and a shared message would hide which is in play.
root="$(make_fixture data_is_a_file "$COMPOSE_SIMPLE")"
printf 'not a directory\n' > "${root}/${APP_ID}/data"
run_case 'wrong type: path exists as a file fails' 1 "$root" 'is not a directory'

# UNRECOGNISED SHAPE — a long-form `type: bind` volume declares a source in a
# shape this check does not parse, which is exactly where a real missing
# directory would hide if the line were passed over.
root="$(make_fixture longform_bind "services:
  server:
    image: example/app:1.0.0
    volumes:
      - type: bind
        source: \${APP_DATA_DIR}/data
        target: /data")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'unrecognised: long-form type/source volume fails closed' 1 "$root" "unrecognised \${APP_DATA_DIR} line shape"

# TRAILING COMMENT — valid YAML, and the real compose file comments heavily
# around this exact line. A gate that refuses valid work fails in the direction
# that looks safe.
root="$(make_fixture trailing_comment "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data  # survives updates, removed on uninstall")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'variant: trailing comment on the volume line passes' 0 "$root" 'OK'

# TWO VOLUMES — every declared source is asserted, not just the first.
readonly COMPOSE_TWO_VOLUMES="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data
      - \${APP_DATA_DIR}/cache:/cache"

root="$(make_fixture two_volumes_one_shipped "$COMPOSE_TWO_VOLUMES")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'two volumes: second declared dir missing fails' 1 "$root" "${APP_ID}/cache does not exist"

root="$(make_fixture two_volumes_both_shipped "$COMPOSE_TWO_VOLUMES")"
mkdir -p "${root}/${APP_ID}/data" "${root}/${APP_ID}/cache"
run_case 'two volumes: both declared dirs present passes' 0 "$root" "${APP_ID}/data ${APP_ID}/cache"

# env_file LONG-FORM PATH ENTRY — recognised and excluded from the directory
# assertion. The exclusion is proven rather than assumed: without these cases an
# implementation that merely fell through would look identical to one that
# classified the line on purpose, and the exclusion must not become a second way
# to satisfy the check.
root="$(make_fixture env_file_entry "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'env_file: long-form path entry beside a satisfied volume passes' 0 "$root" 'OK'

root="$(make_fixture env_file_only "services:
  server:
    image: example/app:1.0.0
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'env_file: an env_file path alone declares no volume and fails closed' 1 "$root" "no short-form \${APP_DATA_DIR} volume entry found"

# ADVERSARIAL comment collisions. The real compose file quotes ${APP_DATA_DIR}
# in prose, once in a full `${APP_DATA_DIR}/data:/data` shape, so both
# directions are live: a comment must not be read as a declaration, and must not
# satisfy the check either. These assert on the extracted path, not just the
# exit code — a case checking only the exit code passes while the check reads
# the wrong line.
root="$(make_fixture adversarial_comment_masks "services:
  server:
    image: example/app:1.0.0
    # The shipped-app precedent is vaultwarden's \${APP_DATA_DIR}/prose:/prose.
    volumes:
      - \${APP_DATA_DIR}/data:/data")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'adversarial: a volume-shaped mention in a comment is not a declaration' 0 "$root" "shipped: ${APP_ID}/data"

root="$(make_fixture adversarial_comment_only "services:
  server:
    image: example/app:1.0.0
    # Precedent for a future release: \${APP_DATA_DIR}/data:/data.
    restart: on-failure")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'adversarial: a volume named only in a comment does not satisfy the check' 1 "$root" 'declares no app-data path'

# The same collision class on the volume line ITSELF, which whole-line comment
# handling cannot reach: a TRAILING comment carrying a second
# `${APP_DATA_DIR}/…:/…` token. This is the case that failed twice on the
# sibling check — a greedy strip reads the value out of the LAST occurrence.
# Both directions are pinned on the extracted path, because the first alone
# passes green under a greedy extraction whenever the commented path exists.
readonly COMPOSE_TRAILING_COLLISION="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data  # was \${APP_DATA_DIR}/legacy:/data before the rename"

root="$(make_fixture adversarial_trailing_false_reject "$COMPOSE_TRAILING_COLLISION")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'adversarial: a second path in a trailing comment must NOT cause a false reject' 0 "$root" "shipped: ${APP_ID}/data"

root="$(make_fixture adversarial_trailing_masks "$COMPOSE_TRAILING_COLLISION")"
mkdir -p "${root}/${APP_ID}/legacy"
run_case 'adversarial: a second path in a trailing comment must NOT mask a missing dir' 1 "$root" "${APP_ID}/data does not exist"

# MALFORMED SUBPATH — `${APP_DATA_DIR}/:/data` matches the volume shape but
# extracts an empty subpath, which resolves to the app directory itself.
root="$(make_fixture empty_subpath "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/:/data")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'malformed: empty host subpath fails closed' 1 "$root" 'unusable host-side subpath'

# PATH TRAVERSAL — `.` and `..` pass SUBPATH_ERE's character class but are
# navigation, not names, and would be concatenated into the target with no
# containment check. Shipping the directory the traversal points at must not
# make it pass: the segment itself is the defect.
root="$(make_fixture traversal_dotdot "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/../evil/data:/data")"
mkdir -p "${root}/evil/data"
run_case 'traversal: leading .. segment fails closed even when the escape target exists' 1 "$root" "segment '..'"

root="$(make_fixture traversal_dot "services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data/./sub:/data")"
mkdir -p "${root}/${APP_ID}/data/sub"
run_case 'traversal: embedded . segment fails closed' 1 "$root" "segment '.'"

# SYMLINK ESCAPE — `.`/`..` are rejected in the compose STRING above, but
# `[[ -e ]]` and `[[ -d ]]` FOLLOW symlinks, so a symlinked component escapes
# without any traversal segment. The LEAF, an INTERMEDIATE component of a nested
# subpath, and an ordinary real directory are all pinned.
root="$(make_fixture symlink_leaf "$COMPOSE_SIMPLE")"
mkdir -p "${scratch}/symlink_leaf_outside_target"
ln -s "${scratch}/symlink_leaf_outside_target" "${root}/${APP_ID}/data"
run_case 'symlink: symlinked leaf fails closed even though it resolves to a real directory' 1 "$root" "${APP_ID}/data' is a symlink"

root="$(make_fixture symlink_intermediate "$COMPOSE_NESTED")"
mkdir -p "${scratch}/symlink_intermediate_outside_target/db"
ln -s "${scratch}/symlink_intermediate_outside_target" "${root}/${APP_ID}/state"
run_case 'symlink: symlinked intermediate component under a nested subpath fails closed' 1 "$root" "${APP_ID}/state' is a symlink"

root="$(make_fixture symlink_none_real_nested "$COMPOSE_NESTED")"
mkdir -p "${root}/${APP_ID}/state/db"
run_case 'symlink: ordinary real nested directory with no symlink still passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/state/db"

# SYMLINK AT THE APP TEMPLATE DIRECTORY ITSELF — the walk's starting value, which
# appending segments never tests. `lstat` resolves intermediate components, so
# every `-L` check on an appended segment would report on entries inside the
# symlink's target instead. This fixture is built by hand because make_fixture
# always creates a real ${APP_ID} directory; the compose file lives INSIDE the
# symlink target so the check reaches the walk rather than the existence guard.
outside_target="${scratch}/symlink_app_dir_outside_target"
mkdir -p "${outside_target}/data"
printf '%s\n' "$COMPOSE_SIMPLE" > "${outside_target}/docker-compose.yml"

root="${scratch}/symlink_app_dir"
mkdir -p "${root}/scripts"
cp "$SCRIPT_UNDER_TEST" "${root}/scripts/check-bind-mount-dirs.sh"
chmod +x "${root}/scripts/check-bind-mount-dirs.sh"
ln -s "$outside_target" "${root}/${APP_ID}"
run_case 'symlink: app template directory itself is a symlink fails closed' 1 "$root" "${APP_ID}' is a symlink"

# QUOTED VOLUME ENTRIES — both quote styles are legal, common Compose
# short-syntax and must pass; a MISMATCHED pair, which enumerating three whole
# forms is exactly what rules out, must still fail closed.
readonly COMPOSE_DQUOTED="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \"\${APP_DATA_DIR}/data:/data\""
root="$(make_fixture quoted_double "$COMPOSE_DQUOTED")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'quoted: double-quoted whole mapping passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/data"

readonly COMPOSE_SQUOTED="services:
  server:
    image: example/app:1.0.0
    volumes:
      - '\${APP_DATA_DIR}/data:/data'"
root="$(make_fixture quoted_single "$COMPOSE_SQUOTED")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'quoted: single-quoted whole mapping passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/data"

readonly COMPOSE_MISMATCHED_QUOTES="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \"\${APP_DATA_DIR}/data:/data'"
root="$(make_fixture quoted_mismatched "$COMPOSE_MISMATCHED_QUOTES")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'quoted: mismatched opening/closing quotes fails closed' 1 "$root" "unrecognised \${APP_DATA_DIR} line shape"

# MOUNT MODE SUFFIX — `:ro` and `:rw` are legal trailing Compose mount modes, so
# a future read-only mount must not break the gate on day one. The suffix is
# also proven independent of quoting, and proven not to mask a missing source.
readonly COMPOSE_RO="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/config:/config:ro"
root="$(make_fixture mode_ro "$COMPOSE_RO")"
mkdir -p "${root}/${APP_ID}/config"
run_case 'mode: :ro suffix passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/config"

readonly COMPOSE_RW="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \${APP_DATA_DIR}/data:/data:rw"
root="$(make_fixture mode_rw "$COMPOSE_RW")"
mkdir -p "${root}/${APP_ID}/data"
run_case 'mode: :rw suffix passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/data"

readonly COMPOSE_QUOTED_RO="services:
  server:
    image: example/app:1.0.0
    volumes:
      - \"\${APP_DATA_DIR}/config:/config:ro\""
root="$(make_fixture mode_ro_quoted "$COMPOSE_QUOTED_RO")"
mkdir -p "${root}/${APP_ID}/config"
run_case 'mode: :ro suffix inside a double-quoted mapping passes' 0 "$root" "OK: every declared app-data bind-mount source is shipped: ${APP_ID}/config"

root="$(make_fixture mode_ro_missing "$COMPOSE_RO")"
run_case 'mode: :ro suffix does not mask a missing bind-mount source' 1 "$root" "${APP_ID}/config does not exist"

# UNREADABLE COMPOSE — distinct from the missing-file case: the guard order puts
# existence before readability so a permission problem names its real cause
# rather than falling through to the zero-declaration diagnostic.
root="$(make_fixture unreadable_compose "$COMPOSE_SIMPLE")"
mkdir -p "${root}/${APP_ID}/data"
chmod 000 "${root}/${APP_ID}/docker-compose.yml"
run_case 'unreadable: permission-denied compose file fails closed with the real cause' 1 "$root" 'compose file not readable'
chmod 644 "${root}/${APP_ID}/docker-compose.yml"

report_summary
