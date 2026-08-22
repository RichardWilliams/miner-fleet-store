#!/usr/bin/env bash
#
# Tests for scripts/release.sh.
#
# Every case builds its own miniature store repo under the harness scratch dir —
# the driver, the three gates it runs, the libraries they source, an app
# manifest and compose file pinned at a previous version, and a git work tree
# with a bare local remote (codespace docs/testing-standards.md § 4.1, hermetic
# fixtures). The remote is there to be asserted EMPTY: the driver commits and
# stops, and a bare repo beside the fixture is what makes "it pushed nothing"
# checkable against a real artefact rather than against the driver's own words.
#
# `docker` and `gh` are STUBBED through a FAKE_BIN directory prepended to PATH,
# and both stubs FAIL CLOSED (exit 64) on any invocation they were not built to
# answer — including a wrong `--repo` slug, a wrong tag, or a wrong API path
# (§ 3.1 fail-closed stubs). No case can silently reach a real registry, a real
# GitHub API, or the network. The `git` calls are real, against a bare repo
# created beside the fixture, so the branch-and-commit path is exercised without
# leaving the machine.
#
# The stubs read their canned answers from files under the fixture's own
# `.stub/` directory, located relative to the stub's own path, so no case has to
# plumb environment variables through a bash function (codespace
# docs/coding-standards.md § 9.1).

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/release.sh"
readonly COMMON_LIB="${repo_root}/scripts/lib/check-common.sh"
readonly CONTEXT_LIB="${repo_root}/scripts/lib/repo-context.sh"
readonly RELEASE_LIB="${repo_root}/scripts/lib/release-context.sh"
readonly PARSER_LIB="${repo_root}/scripts/lib/manifest_data.py"
readonly PATTERNS_LIB="${repo_root}/scripts/lib/secret-patterns.sh"

# The app id, the registry coordinate and both GitHub slugs come from the one
# place that declares them, and the gate list from the one place that declares
# that, so nothing is written a second time here.
for library in "$CONTEXT_LIB" "$RELEASE_LIB"; do
  [[ -f "$library" ]] || {
    printf 'FATAL: library not found at %s\n' "$library" >&2
    exit 1
  }
done
source "$CONTEXT_LIB"
source "$RELEASE_LIB"

readonly PREVIOUS_VERSION="0.2.0"
readonly TARGET_VERSION="0.3.0"
readonly PREVIOUS_DIGEST="sha256:83de64211b8e6b0293df25fa718d387f5a07e8c841da80b5792213461f3d50ab"
readonly INDEX_DIGEST="sha256:27c16fba762479efa4773aa477ede79e96f67bb633c554baa1d820f0429419f8"
# The per-platform digest that sits in the indented `Manifests:` list. Reading
# it instead of the index digest is the mistake DECISIONS.md entry 4 names, and
# it is what the fixture inspect output is built to tempt.
readonly PLATFORM_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

for required in "$SCRIPT_UNDER_TEST" "$COMMON_LIB" "$CONTEXT_LIB" "$RELEASE_LIB" \
  "$PARSER_LIB" "$PATTERNS_LIB"; do
  [[ -f "$required" ]] || {
    printf 'FATAL: file under test not found at %s\n' "$required" >&2
    exit 1
  }
done
for gate in "${RELEASE_GATES[@]}"; do
  [[ -f "${repo_root}/scripts/${gate}.sh" ]] || {
    printf 'FATAL: gate not found at %s\n' "${repo_root}/scripts/${gate}.sh" >&2
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
# Canned upstream answers.
# ---------------------------------------------------------------------------

INSPECT_OUTPUT="$(cat <<INSPECT
Name:      ${UPSTREAM_IMAGE}:${TARGET_VERSION}
MediaType: application/vnd.oci.image.index.v1+json
Digest:    ${INDEX_DIGEST}

Manifests:
  Name:      ${UPSTREAM_IMAGE}:${TARGET_VERSION}@${PLATFORM_DIGEST}
  Digest:    ${PLATFORM_DIGEST}
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64
INSPECT
)"

RELEASE_BODY="$(cat <<'BODY'
Miner Fleet 0.3.0

Firmware versions are now visible across the fleet. Each board shows the
firmware it is running alongside the latest release published for its model.

Two fixes to how the app watches your fleet:

  - Warnings now fire for boards found by network discovery.
  - The app now runs a single polling loop.
BODY
)"

PREVIOUS_BODY="$(cat <<'BODY'
Miner Fleet 0.2.0

The fleet is live.
BODY
)"

CONTRACT_JSON="$(cat <<'CONTRACT'
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

COMPOSE_BODY="$(cat <<COMPOSE
services:
  app_proxy:
    environment:
      APP_HOST: ${APP_ID}_server_1
      APP_PORT: 3000

  server:
    image: ${UPSTREAM_IMAGE}:${PREVIOUS_VERSION}@${PREVIOUS_DIGEST}  # index digest, not per-platform
    restart: on-failure
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
    volumes:
      - \${APP_DATA_DIR}/data:/data
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false
COMPOSE
)"

# ---------------------------------------------------------------------------
# Fixture construction.
# ---------------------------------------------------------------------------

write_docker_stub() {
  cat > "${1}/fake-bin/docker" <<'STUB'
#!/usr/bin/env bash
# Fail-closed docker stub. Answers exactly one invocation shape and refuses
# every other, so no case can reach a real registry by accident.
set -euo pipefail
stub_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub="$(cd -P "${stub_dir}/.." && pwd)/.stub"

if [[ "${1:-}" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" && $# -eq 4 ]]; then
  expected="$(cat "${stub}/expected-image-ref")"
  if [[ "$4" != "$expected" ]]; then
    printf 'docker stub: unexpected image reference %s (expected %s)\n' "$4" "$expected" >&2
    exit 64
  fi
  if [[ -f "${stub}/inspect.fail" ]]; then
    printf 'ERROR: %s: not found\n' "$4" >&2
    exit 1
  fi
  cat "${stub}/inspect.out"
  exit 0
fi

printf 'docker stub: refusing unexpected invocation: %s\n' "$*" >&2
exit 64
STUB
  chmod +x "${1}/fake-bin/docker"
}

write_gh_stub() {
  cat > "${1}/fake-bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fail-closed gh stub. Every answer is canned from the fixture's .stub
# directory, and every invocation shape not enumerated here exits 64 — including
# a wrong --repo slug, a wrong tag, or an unpinned contract path.
set -euo pipefail
stub_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub="$(cd -P "${stub_dir}/.." && pwd)/.stub"

refuse() {
  printf 'gh stub: %s\n' "$1" >&2
  exit 64
}

flag_value() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

upstream_slug="$(cat "${stub}/upstream-slug")"
store_slug="$(cat "${stub}/store-slug")"
version="$(cat "${stub}/version")"

command="${1:-}"
sub="${2:-}"

if [[ "$command" == "release" && "$sub" == "view" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "release view carried no --repo"
  [[ "$repo" == "$upstream_slug" ]] || refuse "release view named ${repo}, not ${upstream_slug}"
  [[ "${3:-}" == "v${version}" ]] || refuse "release view named tag ${3:-}, not v${version}"
  if [[ -f "${stub}/release.fail" ]]; then
    printf 'release not found\n' >&2
    exit 1
  fi
  cat "${stub}/release-body.txt"
  exit 0
fi

if [[ "$command" == "api" ]]; then
  api_path=""
  for argument in "$@"; do
    case "$argument" in
      repos/*) api_path="$argument" ;;
    esac
  done
  [[ -n "$api_path" ]] || refuse "api carried no repos/ path"
  expected="repos/${upstream_slug}/contents/deploy/contract.json?ref=v${version}"
  [[ "$api_path" == "$expected" ]] || refuse "api asked for ${api_path}, not ${expected}"
  if [[ -f "${stub}/contract.fail" ]]; then
    printf 'Not Found\n' >&2
    exit 1
  fi
  cat "${stub}/contract.json"
  exit 0
fi

if [[ "$command" == "pr" && "$sub" == "list" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "pr list carried no --repo"
  [[ "$repo" == "$store_slug" ]] || refuse "pr list named ${repo}, not ${store_slug}"
  if [[ -f "${stub}/pr-number" ]]; then
    cat "${stub}/pr-number"
  fi
  exit 0
fi

if [[ "$command" == "pr" && "$sub" == "create" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "pr create carried no --repo"
  [[ "$repo" == "$store_slug" ]] || refuse "pr create named ${repo}, not ${store_slug}"
  head="$(flag_value --head "$@")" || refuse "pr create carried no --head"
  printf '%s\n' "$head" >> "${stub}/pr-created.log"
  printf '77\n' > "${stub}/pr-number"
  printf 'https://github.com/%s/pull/77\n' "$repo"
  exit 0
fi

refuse "refusing unexpected invocation: $*"
STUB
  chmod +x "${1}/fake-bin/gh"
}

# $1 = fixture name. Returns the fixture root on stdout.
make_fixture() {
  local name="$1"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}" \
    "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}" "${root}/fake-bin" "${root}/.stub"

  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/release.sh"
  chmod +x "${root}/scripts/release.sh"
  local gate=""
  for gate in "${RELEASE_GATES[@]}"; do
    cp "${repo_root}/scripts/${gate}.sh" "${root}/scripts/${gate}.sh"
    chmod +x "${root}/scripts/${gate}.sh"
  done
  cp "$COMMON_LIB" "${root}/scripts/lib/check-common.sh"
  cp "$CONTEXT_LIB" "${root}/scripts/lib/repo-context.sh"
  cp "$RELEASE_LIB" "${root}/scripts/lib/release-context.sh"
  cp "$PARSER_LIB" "${root}/scripts/lib/manifest_data.py"
  cp "$PATTERNS_LIB" "${root}/scripts/lib/secret-patterns.sh"

  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
version: "${PREVIOUS_VERSION}"
port: 3007
releaseNotes: >-
  replaced below by the real emitter
# A load-bearing comment the surgery must not delete.
developer: Pipfox
EOF
  printf '%s\n' "$PREVIOUS_BODY" > "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/release-notes.txt"
  printf '%s\n' "$CONTRACT_JSON" > "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/contract.json"
  python3 "${root}/scripts/lib/manifest_data.py" set-block \
    "${root}/${APP_ID}/umbrel-app.yml" releaseNotes \
    "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/release-notes.txt" \
    "$NOTES_BLOCK_INDENT"

  printf '%s\n' "$COMPOSE_BODY" > "${root}/${APP_ID}/docker-compose.yml"

  printf '%s\n' "$INSPECT_OUTPUT" > "${root}/.stub/inspect.out"
  printf '%s\n' "$RELEASE_BODY" > "${root}/.stub/release-body.txt"
  printf '%s\n' "$CONTRACT_JSON" > "${root}/.stub/contract.json"
  printf '%s' "${UPSTREAM_IMAGE}:${TARGET_VERSION}" > "${root}/.stub/expected-image-ref"
  printf '%s' "$UPSTREAM_REPO_SLUG" > "${root}/.stub/upstream-slug"
  printf '%s' "$STORE_REPO_SLUG" > "${root}/.stub/store-slug"
  printf '%s' "$TARGET_VERSION" > "${root}/.stub/version"

  write_docker_stub "$root"
  write_gh_stub "$root"

  git init --quiet "$root"
  git -C "$root" symbolic-ref HEAD refs/heads/main
  git -C "$root" config user.email "release-driver-tests@example.invalid"
  git -C "$root" config user.name "Release Driver Tests"
  git -C "$root" add --all
  git -C "$root" commit --quiet -m "fixture: the store at ${PREVIOUS_VERSION}"
  git init --quiet --bare "${root}.git"
  git -C "$root" remote add origin "${root}.git"

  printf '%s' "$root"
}

# $1 = description, $2 = expected exit, $3 = substring, $4 = fixture root,
# $5... = the driver's own arguments.
run_release() {
  local desc="$1" expected="$2" substring="$3" root="$4"
  shift 4
  local saved_path="$PATH"
  export PATH="${root}/fake-bin:${saved_path}"
  assert_case "$desc" "$expected" "$substring" bash "${root}/scripts/release.sh" "$@"
  export PATH="$saved_path"
}

# A snapshot-run-compare helper, so "the tree is untouched" is asserted against
# the actual bytes rather than against the driver's own claim.
readonly UNTOUCHED_CHECK="${scratch}/assert-tree-untouched.sh"
cat > "$UNTOUCHED_CHECK" <<'UNTOUCHED'
#!/usr/bin/env bash
# $1 = fixture root, $2 = version argument.
set -euo pipefail
root="$1"
version="$2"

# The fixture's own copy of the context library names the two directories a
# release bump may write to, so this helper reads them from the same
# declaration the driver does.
source "${root}/scripts/lib/repo-context.sh"

snapshot() {
  cd "$root"
  find "${APP_ID}" "${VENDOR_REL_DIR}" -type f | sort | while read -r entry; do
    printf '=== %s\n' "$entry"
    cat "$entry"
  done
}

before="$(snapshot)"
driver_exit=0
PATH="${root}/fake-bin:${PATH}" bash "${root}/scripts/release.sh" "$version" \
  > "${root}/.stub/driver.out" 2>&1 || driver_exit=$?
after="$(snapshot)"

if [[ "$before" != "$after" ]]; then
  printf 'the driver modified the tree; it should not have\n' >&2
  exit 1
fi
printf 'tree untouched, driver exited %d\n' "$driver_exit"
UNTOUCHED

# The driver's own run-and-check-absence helper. assert_case can require a
# substring to be PRESENT; the property here is that one is ABSENT, because a
# refusal that quoted the credential would disclose it into the terminal and the
# CI log of every run that reproduced it.
readonly NO_ECHO_CHECK="${scratch}/assert-driver-secret-not-echoed.sh"
cat > "$NO_ECHO_CHECK" <<'NOECHO'
#!/usr/bin/env bash
# $1 = fixture root, $2 = version argument, $3 = the literal that must not
# appear anywhere in the driver's output.
set -euo pipefail
seen=""
seen="$(PATH="${1}/fake-bin:${PATH}" bash "${1}/scripts/release.sh" "$2" 2>&1)" || true

if [[ "$seen" == *"$3"* ]]; then
  printf 'the driver echoed the matched credential back into its own output\n' >&2
  exit 1
fi
printf 'driver named the category and not the credential\n'
NOECHO

# capture_release — run the driver with the stubs on PATH and save its combined
# output to the fixture's own .stub/driver.out.
#
# assert_case can require a substring to be PRESENT in the output of the command
# it runs, which covers one string per run. The hand-off has to be asserted on
# several times over — once per declared gate — and once for a string that must
# be ABSENT. Saving the output to a file lets each of those be its own case,
# with `grep` as the command and its exit code as the polarity, rather than
# re-running the driver for every assertion.
capture_release() {
  local root="$1"
  shift
  local saved_path="$PATH"
  export PATH="${root}/fake-bin:${saved_path}"
  bash "${root}/scripts/release.sh" "$@" > "${root}/.stub/driver.out" 2>&1 || true
  export PATH="$saved_path"
}

# The number of commits the driver added on top of the fixture's own main.
count_release_commits() {
  printf 'commits on the release branch: %s\n' \
    "$(git -C "$1" rev-list --count "main..refs/heads/release-${TARGET_VERSION}")"
}

# The hand-off's own comparison. Every other case built on a captured
# driver.out runs `grep` as its command, which is line-based and so cannot see a
# property spanning two lines of the printed command. This reads the whole
# capture into one string and compares it against an expected value that carries
# its own line breaks, which is what lets a case assert the COMPOSED invocation
# rather than the presence of the words in it.
readonly HANDOFF_CHECK="${scratch}/assert-handoff-command.sh"
cat > "$HANDOFF_CHECK" <<'HANDOFF'
#!/usr/bin/env bash
# $1 = the captured driver output, $2 = the composed invocation it must carry,
# line breaks and all.
set -euo pipefail
if [[ "$(cat "$1")" != *"$2"* ]]; then
  printf 'the hand-off did not carry the expected invocation:\n%s\n' "$2" >&2
  exit 1
fi
printf 'the hand-off carries the composed invocation\n'
HANDOFF

readonly PR_COUNT_CHECK="${scratch}/count-created-prs.sh"
cat > "$PR_COUNT_CHECK" <<'COUNT'
#!/usr/bin/env bash
# $1 = the stub's pr-created log.
set -euo pipefail
if [[ -f "$1" ]]; then
  printf 'pr create invocations: %s\n' "$(grep -c '' "$1")"
else
  printf 'pr create invocations: 0\n'
fi
COUNT

# ---------------------------------------------------------------------------
# THE ARGUMENT IS A VERSION, NEVER A DIGEST. The driver resolves the digest from
# the registry itself, so there is no argument, and no file produced upstream,
# that could carry one in.
# ---------------------------------------------------------------------------
root="$(make_fixture rejects_digest_argument)"
run_release 'argument: a tag@digest argument is rejected' 1 'never accepts a digest' \
  "$root" "${TARGET_VERSION}@${INDEX_DIGEST}"
run_release 'argument: a bare digest argument is rejected' 1 'never accepts a digest' \
  "$root" "$INDEX_DIGEST"
run_release 'argument: a non-semver argument is rejected' 1 'is not a semver' "$root" 'latest'
run_release 'argument: no argument at all is rejected' 1 'usage' "$root"

# ---------------------------------------------------------------------------
# THE HAPPY PATH. One run rewrites the version, the image tag and the digest
# together, vendors both upstream artefacts, commits them — and stops there.
# ---------------------------------------------------------------------------
root="$(make_fixture happy_path)"
run_release 'release: a clean run succeeds' 0 'done' "$root" "$TARGET_VERSION"

assert_case 'digest: the pinned digest is the TOP-LEVEL Digest, not the indented per-platform one' \
  0 "${TARGET_VERSION}@${INDEX_DIGEST}" \
  grep -F 'image:' "${root}/${APP_ID}/docker-compose.yml"

assert_case 'digest: the per-platform digest from the Manifests list is never pinned' \
  1 '' grep -F "$PLATFORM_DIGEST" "${root}/${APP_ID}/docker-compose.yml"

assert_case 'bump: the manifest version is rewritten' 0 "$TARGET_VERSION" \
  python3 "$PARSER_LIB" get "${root}/${APP_ID}/umbrel-app.yml" version

assert_case 'bump: the listing carries the upstream Release body' 0 'Firmware versions are now visible' \
  python3 "$PARSER_LIB" get "${root}/${APP_ID}/umbrel-app.yml" releaseNotes

assert_case 'bump: the manifest surgery preserved the surrounding comment' 0 'load-bearing comment' \
  grep -F '# A load-bearing comment' "${root}/${APP_ID}/umbrel-app.yml"

assert_case 'bump: version drift passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-version-drift.sh"

assert_case 'bump: release-notes drift passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-release-notes-drift.sh"

assert_case 'bump: the deployment contract passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-deploy-contract.sh"

assert_case 'bump: the credential gate passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-secret-leak.sh"

assert_case 'vendor: the new version directory is written' 0 '' \
  test -f "${root}/${VENDOR_REL_DIR}/v${TARGET_VERSION}/contract.json"

assert_case 'vendor: the previous version directory is removed' 1 '' \
  test -d "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}"

# ---------------------------------------------------------------------------
# THE DRIVER STOPS SHORT OF THE PUSH (DECISIONS.md entry 16). The push-time
# gates fire when the driver is INVOKED and evaluate HEAD as it stands then —
# the commit BEFORE the bump. A push from inside the driver would therefore
# carry a SHA nothing had validated, so the driver commits and hands the push
# back. These four cases assert that against real artefacts: the bare remote
# beside the fixture, the fixture's own git history, and the stub's log of
# every `gh pr create` it was asked for.
# ---------------------------------------------------------------------------
assert_case 'stop-short: the driver pushed nothing to the remote' 1 '' \
  git -C "${root}.git" rev-parse --verify --quiet "refs/heads/release-${TARGET_VERSION}"

assert_case 'stop-short: the driver opened no PR' 0 'pr create invocations: 0' \
  bash "$PR_COUNT_CHECK" "${root}/.stub/pr-created.log"

assert_case 'stop-short: the bump IS committed on the release branch' \
  0 "chore(release): pin miner-fleet ${TARGET_VERSION}" \
  git -C "$root" log -1 --format=%s "refs/heads/release-${TARGET_VERSION}"

run_release 'stop-short: the run says nothing has been pushed' 0 'NOTHING has been pushed' \
  "$root" "$TARGET_VERSION"

run_release 'hand-off: the run prints the push command the operator runs next' \
  0 'push --set-upstream' "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# RESUMABLE, OFF REAL ARTEFACTS. A second run for the same version rewrites the
# same content, makes no second commit — decided by the index against HEAD, not
# by anything the first run wrote down — and still pushes and opens nothing.
# ---------------------------------------------------------------------------
run_release 'resume: a re-run for the same version succeeds' 0 'no new commit needed' \
  "$root" "$TARGET_VERSION"

assert_case 'resume: the re-run added no second commit' \
  0 'commits on the release branch: 1' count_release_commits "$root"

assert_case 'resume: still nothing pushed' 1 '' \
  git -C "${root}.git" rev-parse --verify --quiet "refs/heads/release-${TARGET_VERSION}"

assert_case 'resume: still no PR opened' 0 'pr create invocations: 0' \
  bash "$PR_COUNT_CHECK" "${root}/.stub/pr-created.log"

# What exp-109 was protecting — a resumed release must not be handed a second
# PR — is kept, and is read from GitHub's own open-PR list rather than from a
# state file. Seeding the stub's pr-number is the operator having opened the PR
# between the two runs.
printf '77\n' > "${root}/.stub/pr-number"
run_release 'resume: with the PR already open the driver names it' 0 'already open' \
  "$root" "$TARGET_VERSION"

capture_release "$root" "$TARGET_VERSION"
assert_case 'resume: and does not hand back a command that would open a second' \
  1 '' grep -F 'gh pr create' "${root}/.stub/driver.out"

# ---------------------------------------------------------------------------
# A MISSING OR EMPTY RELEASE IS A HARD FAILURE, and it leaves the tree alone.
# There is no fall-through to hand-written notes.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_release)"
touch "${root}/.stub/release.fail"
run_release 'release notes: a missing upstream Release is a hard failure' 1 'A missing Release is a hard failure' \
  "$root" "$TARGET_VERSION"
assert_case 'release notes: a missing Release leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture empty_release)"
: > "${root}/.stub/release-body.txt"
run_release 'release notes: an empty upstream Release body is a hard failure' 1 'empty body' \
  "$root" "$TARGET_VERSION"
assert_case 'release notes: an empty Release body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# MARKDOWN IS REFUSED, with the verified community-store rationale. All three
# shapes the acceptance criteria name.
# ---------------------------------------------------------------------------
root="$(make_fixture markdown_bold)"
printf 'Discovery is **live** now.\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a bold body is refused' 1 "contains '**'" "$root" "$TARGET_VERSION"
run_release 'markdown: the refusal cites the community-store bypass' 1 'bypasses react-markdown' \
  "$root" "$TARGET_VERSION"

root="$(make_fixture markdown_link)"
printf 'See [the docs](https://example.invalid/docs).\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a link body is refused' 1 'markdown link' "$root" "$TARGET_VERSION"
run_release 'markdown: the link refusal cites the community-store bypass' 1 'whitespace-pre-line' \
  "$root" "$TARGET_VERSION"

root="$(make_fixture markdown_heading)"
printf '# Heading\n\nBody text.\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a heading body is refused' 1 'markdown heading' "$root" "$TARGET_VERSION"
assert_case 'markdown: a refused body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# THE CONTRACT ASSERTION RUNS BEFORE ANY FILE IS WRITTEN. A mismatch leaves the
# tree completely untouched — including the vendored artefacts themselves, which
# is what the temp-staging design buys.
# ---------------------------------------------------------------------------
root="$(make_fixture contract_mismatch)"
printf '%s\n' "$CONTRACT_JSON" \
  | sed -E 's/"containerPort": 3000/"containerPort": 4000/' \
  > "${root}/.stub/contract.json"
run_release 'contract: a mismatch fails the release' 1 'is not satisfied by the current' \
  "$root" "$TARGET_VERSION"
run_release 'contract: the failure names the container-port mismatch' 1 'container-port mismatch' \
  "$root" "$TARGET_VERSION"
assert_case 'contract: a mismatch leaves the tree completely untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture contract_missing_at_tag)"
touch "${root}/.stub/contract.fail"
run_release 'contract: a tag whose tree carries no contract is a hard failure' 1 'at tag v' \
  "$root" "$TARGET_VERSION"
assert_case 'contract: an absent contract leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# A CREDENTIAL IN EITHER FETCHED ARTEFACT IS REFUSED BEFORE ANYTHING IS WRITTEN.
# This repo is public and its history is permanent; the repo these two artefacts
# are copied FROM is private. The refusal names the CATEGORY and never the
# matched text, and it leaves the tree untouched, exactly as the markdown and
# contract refusals do (DECISIONS.md entry 15).
#
# The fixture values are not credentials: the AWS row is the key id AWS
# publishes in its own documentation as the example value, and the GitHub row is
# EXAMPLE filler at the length the shape requires.
# ---------------------------------------------------------------------------
readonly EXAMPLE_AWS_KEY='AKIAIOSFODNN7EXAMPLE'
readonly EXAMPLE_GITHUB_TOKEN='ghp_EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPL0'

root="$(make_fixture release_body_credential)"
printf 'The fleet is live.\n\nPasted by mistake: %s\n' "$EXAMPLE_GITHUB_TOKEN" \
  > "${root}/.stub/release-body.txt"
run_release 'credential: a Release body carrying a GitHub token is refused' \
  1 'Release body contains a GitHub token' "$root" "$TARGET_VERSION"
run_release 'credential: the refusal says the tree was not written' \
  1 'Nothing has been written' "$root" "$TARGET_VERSION"
assert_case 'credential: a refused Release body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"
assert_case 'credential: the Release-body refusal never echoes the matched token' \
  0 'driver named the category and not the credential' \
  bash "$NO_ECHO_CHECK" "$root" "$TARGET_VERSION" "$EXAMPLE_GITHUB_TOKEN"

# The contract, whose `documentation.*` fields are free prose, had no content
# check at all before this refusal existed.
root="$(make_fixture contract_credential)"
printf '%s\n' "$CONTRACT_JSON" \
  | sed -E "s|\"purpose\": \"[^\"]*\"|\"purpose\": \"deploy with ${EXAMPLE_AWS_KEY}\"|" \
  > "${root}/.stub/contract.json"
run_release 'credential: a contract carrying an AWS access-key ID is refused' \
  1 'contains an AWS access-key ID' "$root" "$TARGET_VERSION"
assert_case 'credential: a refused contract leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"
assert_case 'credential: the contract refusal never echoes the matched key' \
  0 'driver named the category and not the credential' \
  bash "$NO_ECHO_CHECK" "$root" "$TARGET_VERSION" "$EXAMPLE_AWS_KEY"

# The refusal is a SHAPE check, not an address check. This app sweeps the
# operator's LAN and its release notes say so, so a body naming a private-range
# subnet must still cut a release (DECISIONS.md entry 15).
root="$(make_fixture private_range_body_allowed)"
printf 'Miner Fleet %s\n\nSet MINER_FLEET_SUBNETS=192.168.1.0/24 in config.env on the box.\nThe health probe answers on 127.0.0.1 inside the container.\n' \
  "$TARGET_VERSION" > "${root}/.stub/release-body.txt"
run_release 'credential: a body naming a private-range subnet still releases' \
  0 'done' "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# A REGISTRY THAT CANNOT ANSWER IS A HARD FAILURE, never a fall-through to a
# digest carried in from somewhere else.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_image)"
touch "${root}/.stub/inspect.fail"
run_release 'digest: an unresolvable tag is a hard failure' 1 'imagetools inspect' \
  "$root" "$TARGET_VERSION"
assert_case 'digest: an unresolvable tag leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture no_top_level_digest)"
printf 'Name: %s:%s\n\nManifests:\n  Digest:    %s\n' \
  "$UPSTREAM_IMAGE" "$TARGET_VERSION" "$PLATFORM_DIGEST" > "${root}/.stub/inspect.out"
run_release 'digest: inspect output with no top-level Digest line fails closed' 1 'found 0' \
  "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# ONE DECLARATION OF THE VENDORED DIRECTORY NAME. The driver WRITES the vendored
# directory and the gates it re-runs in step 9 READ it, so a name spelled twice
# would let the writer and the readers disagree. This case redeclares the name in
# the fixture's own copy of the context library: the driver must write under the
# redeclared name, and its own post-write verification must then find it there,
# or the run fails.
#
# It also pins the boundary the other way. The upstream git tag is spelled
# `v${version}` too but is miner-fleet's, not this repo's, so the driver does NOT
# route its `gh` reads through the vendored-name derivation — and the fail-closed
# `gh` stub refuses any tag other than v0.3.0, so a driver that did would fail
# this case rather than pass it quietly.
# ---------------------------------------------------------------------------
root="$(make_fixture redeclared_dir_name)"
redeclare_vendor_dir_name "${root}/scripts/lib/repo-context.sh" 'rel-'
run_release 'one declaration: the driver vendors under a redeclared directory name' \
  0 'done' "$root" "$TARGET_VERSION"

assert_case 'one declaration: both artefacts land under the redeclared name' 0 '' \
  test -f "${root}/${VENDOR_REL_DIR}/rel-${TARGET_VERSION}/${VENDOR_CONTRACT_NAME}"

assert_case 'one declaration: nothing is left under the old spelling' 1 '' \
  test -e "${root}/${VENDOR_REL_DIR}/v${TARGET_VERSION}"

# ---------------------------------------------------------------------------
# THE HAND-OFF'S GATE SENTENCE IS BUILT FROM THE ONE DECLARATION, NOT TYPED
# BESIDE IT. The PR body the driver hands back names the gates the run verified
# with, and a sentence written out there is a second copy of RELEASE_GATES in
# prose — the copy this replaced had already drifted, naming three gates while
# the array ran four, having missed check-secret-leak.sh when that gate was
# added.
#
# The first case requires every declared gate to be named. That alone would stay
# green against a hand-written sentence that happened to agree today, so the
# second REDECLARES the array in the fixture's own copy of the release-context
# library and requires the sentence to follow it — which only a built one can
# do. The redeclaration is APPENDED: the declarations in that library are plain
# assignments precisely so a later one supersedes an earlier one, and the driver
# sources the file once.
# ---------------------------------------------------------------------------
root="$(make_fixture hand_off_gate_list)"
capture_release "$root" "$TARGET_VERSION"

for gate in "${RELEASE_GATES[@]}"; do
  assert_case "hand-off: the PR body names ${gate}.sh" 0 '' \
    grep -F "\`${gate}.sh\`" "${root}/.stub/driver.out"
done

root="$(make_fixture redeclared_gate_list)"
printf '\nRELEASE_GATES=(\n  check-version-drift\n)\n' \
  >> "${root}/scripts/lib/release-context.sh"
capture_release "$root" "$TARGET_VERSION"

assert_case 'one declaration: the redeclared run still succeeds' 0 '' \
  grep -F 'release: done' "${root}/.stub/driver.out"

assert_case 'one declaration: the PR body follows a redeclared gate list' 0 '' \
  grep -F '`check-version-drift.sh`' "${root}/.stub/driver.out"

assert_case 'one declaration: a gate no longer declared is not named' 1 '' \
  grep -F '`check-secret-leak.sh`' "${root}/.stub/driver.out"

# ---------------------------------------------------------------------------
# THE HAND-OFF NAMES THE RIGHT PR. The driver prints the `gh pr create` command
# and never runs one (DECISIONS.md entry 16), so that printed command is the
# SOLE path by which the release PR is opened and nothing else in this repo
# checks how it is composed. A wrong `--repo` would open the PR against another
# repo, a wrong `--head` against another branch, and a wrong `--title` would
# carry a squash-merge subject naming the wrong version — none of which any gate
# or any other case here would catch, because the command is text the operator
# runs later rather than a call this suite's fail-closed `gh` stub ever sees.
#
# The WHOLE composed invocation is asserted rather than the presence of the
# three flags, so a value substituted for another fails the case. The slug is
# read from the one declaration; the branch prefix and the title are the
# driver's own spellings, and a change to either goes red here.
# ---------------------------------------------------------------------------
root="$(make_fixture hand_off_command)"
capture_release "$root" "$TARGET_VERSION"

expected_handoff="$(printf '  gh pr create --repo %s --head release-%s \\\n    --title "chore(release): pin miner-fleet %s" \\\n' \
  "$STORE_REPO_SLUG" "$TARGET_VERSION" "$TARGET_VERSION")"

assert_case 'hand-off: the printed gh pr create carries the right --repo, --head and --title' \
  0 'the hand-off carries the composed invocation' \
  bash "$HANDOFF_CHECK" "${root}/.stub/driver.out" "$expected_handoff"

# ---------------------------------------------------------------------------
# EVERY DECLARED GATE ALSO RUNS AT PUSH TIME. `.local-ci.yml` is the one site
# naming these gates that can neither read RELEASE_GATES nor be built from it —
# it is YAML, it can source nothing, and it carries a named step, a timeout and a
# rationale per gate as well as six test suites. So the agreement is asserted
# instead of assumed: a gate added to the array and forgotten there would run at
# bump time and never at push time, which is the silent half of exactly the drift
# the single declaration exists to end.
#
# This case reads the REAL .local-ci.yml at the repo root rather than a fixture
# copy, because the property is about this repo's own wiring.
# ---------------------------------------------------------------------------
local_ci_step_count() {
  printf 'steps running %s: %s\n' "$1" \
    "$(grep -cE "^[[:space:]]+run:[[:space:]]+bash[[:space:]]+scripts/${1}\.sh[[:space:]]*$" \
      "${repo_root}/.local-ci.yml" || true)"
}

for gate in "${RELEASE_GATES[@]}"; do
  assert_case "push-time: ${gate}.sh runs as a .local-ci.yml step" \
    0 "steps running ${gate}: 1" local_ci_step_count "$gate"
done

report_summary
