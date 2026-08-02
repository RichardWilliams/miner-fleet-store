#!/usr/bin/env bash
#
# Fail when the compose file declares a host-side bind-mount source under
# ${APP_DATA_DIR} that this repo does not ship as a committed directory inside
# the app template.
#
# WHY. On a fresh install, umbreld materialises an app's data directory by
# copying the STORE'S APP TEMPLATE into it, and nothing else puts anything
# there:
#
#   1. `getumbrel/umbrel` @ master, packages/umbreld/source/modules/apps/apps.ts
#      lines 302-308 — `install()` does `fse.mkdirp(appDataDirectory)` then
#      `rsync --archive --verbose --exclude ".gitkeep"
#      ${appTemplatePath}/. ${appDataDirectory}`. That rsync is the ONLY thing
#      that materialises app-data. The apps module has no chown except
#      apps.ts:169 (`sudo chown -R 1000:1000 .../tor`).
#   2. `rsync --archive --exclude ".gitkeep"` DOES create the destination
#      directory while skipping the `.gitkeep` file itself — which is exactly
#      why upstream excludes it by name.
#   3. So umbreld pre-creates a bind-mount source subdirectory ONLY IF the store
#      repo ships that directory in the app template. Otherwise Docker creates
#      it root:root at `compose up`.
#   4. Falsification sweep of `getumbrel/umbrel-apps`: of 333 apps that mount
#      ${APP_DATA_DIR}/data, 332 ship a committed `data/` directory (e.g.
#      vaultwarden/data/.gitkeep).
#
# A root:root source is fatal for THIS app in particular. The container runs as
# uid 1000 under `cap_drop: ALL` + `no-new-privileges:true` (DECISIONS.md entry
# 6), so it cannot create its SQLite database inside a root-owned /data and has
# no way to take ownership of it: SQLITE_CANTOPEN (errcode 14), then a crash
# loop, on every fresh install. Receipt: issue #8.
#
# The invariant this check enforces is therefore a STORE-SIDE one, checkable
# here and nowhere else: every host-side bind-mount source path the app's
# `docker-compose.yml` declares under ${APP_DATA_DIR}/… must exist as a
# committed directory inside the app template directory.
#
# FAIL-CLOSED. A file that is missing, a line the check cannot classify, or a
# subpath that does not match the expected shape is a FAILURE, never a skip. A
# check that silently passes when it cannot read its inputs is worse than no
# check: it reports safety it never established.
#
# Scope: what the compose file declares versus what this repo ships. It does not
# inspect an installed box, and it asserts nothing about ownership at runtime —
# ownership on the box is downstream of what this repo ships, and what this repo
# ships is the half under this repo's control.

set -euo pipefail

# Resolve the repo root from this script's own location so the check runs
# correctly from any working directory, in the container and on the host alike.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

readonly APP_ID="pipfox-miner-fleet"
compose="${repo_root}/${APP_ID}/docker-compose.yml"

fail() {
  printf 'check-bind-mount-dirs: FAIL: %s\n' "$1" >&2
  exit 1
}

# Guard order: required files before any parsing, so a missing file produces a
# clear diagnostic rather than an empty-match error further down.
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"

# The literal token, for the `grep -F` collection and for diagnostics. The `$`
# is escaped so bash yields the token itself rather than the value of a variable
# by that name — which, inside a compose file this script only reads, it has no
# business resolving.
readonly APP_DATA_TOKEN="\${APP_DATA_DIR}"

# POSIX ERE only — no \d, \s or \b (INVARIANTS.md § Tool invocation
# correctness). Bash's `[[ =~ ]]` parses the same dialect `grep -E` does.
#
# `$`, `{` and `}` are ERE metacharacters, so each is escaped; the patterns are
# single-quoted so bash passes the backslashes through untouched. Negated
# bracket expressions put `:` AFTER the character class (`[^[:space:]:]`) so a
# leading `[:` can never be read as the start of a class name.
readonly APP_DATA_ERE='\$\{APP_DATA_DIR\}'
readonly LIST_ITEM_ERE='^[[:space:]]*-[[:space:]]+'
readonly TRAILING_ERE='[[:space:]]*(#.*)?$'
readonly SUBPATH_ERE='[[:alnum:]._-]+(/[[:alnum:]._-]+)*'
readonly COMMENT_LINE_ERE='^[[:space:]]*#'

# Shape 1 — short-form volume entry: `- ${APP_DATA_DIR}/<host>:<container>`.
# Capture group 1 is the host-side subpath: by construction the text between the
# `${APP_DATA_DIR}/` prefix this pattern anchored on and the `:` that separates
# host side from container side.
#
# Extraction is BY CAPTURE GROUP on the anchored match, never by stripping a
# greedy `.*` prefix off the line. That is load-bearing, not style: the sibling
# check-version-drift.sh once extracted its value with an unanchored
# `s|^.*/miner-fleet:||`, and once trailing comments became legal input a
# comment containing a second matching token made sed strip through the LAST
# occurrence — reading the value out of the COMMENT and producing a false PASS
# on real drift. This line carries the same hazard (a `${APP_DATA_DIR}`-shaped
# path is exactly the kind of thing a comment beside it quotes) and the same
# rule applies.
readonly VOLUME_ERE="${LIST_ITEM_ERE}${APP_DATA_ERE}/([^[:space:]:]*):(/[^[:space:]:]*)${TRAILING_ERE}"

# Shape 2 — long-form `env_file` path entry: `- path: ${APP_DATA_DIR}/<...>`.
readonly ENV_FILE_ERE="${LIST_ITEM_ERE}path:[[:space:]]+${APP_DATA_ERE}/[^[:space:]]+${TRAILING_ERE}"

# Collect every line that references the token, minus whole-line YAML comments.
#
# The comment exclusion is not a convenience: this compose file's own prose
# quotes the token four times, once in a full `${APP_DATA_DIR}/data:/data` shape
# (the vaultwarden precedent). A comment declares nothing — Docker never creates
# a directory because of prose — so a commented line is neither a mount to
# assert on nor an unclassifiable input to fail on. Excluding it is also the
# fail-closed direction on the only axis that matters: a comment can never
# SATISFY the check, so a mount that exists solely inside prose still fails as
# "no volume entry found" rather than passing on a directory nobody declared.
declared_lines=()
while IFS= read -r line; do
  if [[ "$line" =~ $COMMENT_LINE_ERE ]]; then
    continue
  fi
  declared_lines+=("$line")
done < <(grep -F "$APP_DATA_TOKEN" "$compose")

# Zero is a FAILURE, not a pass. This check exists to verify app-data paths; a
# compose that declares none means the file changed shape or this script is
# reading the wrong thing. Reporting OK there would report safety it never
# established.
if (( ${#declared_lines[@]} == 0 )); then
  fail "no ${APP_DATA_TOKEN} declaration found in ${compose} — the file declares no app-data path, so this check verified nothing. Either the compose file changed shape or this check is reading the wrong file."
fi

# Classify every collected line into exactly one recognised shape. The two
# arrays are parallel: index i of one corresponds to index i of the other, so
# the failure message downstream can name the exact line a subpath came from.
host_subpaths=()
source_lines=()

for line in "${declared_lines[@]}"; do
  if [[ "$line" =~ $VOLUME_ERE ]]; then
    subpath="${BASH_REMATCH[1]}"
    if [[ ! "$subpath" =~ ^${SUBPATH_ERE}$ ]]; then
      fail "unusable host-side subpath '${subpath}' extracted from ${APP_ID}/docker-compose.yml line '${line}' — expected a relative path of name segments. A subpath this check cannot resolve to a repo path is a failure, not a skip."
    fi
    host_subpaths+=("$subpath")
    source_lines+=("$line")
    continue
  fi

  # An `env_file` path names a FILE that Compose READS, not a bind-mount source
  # Docker CREATES, so it is not what this check asserts on — the operator
  # creates `config.env` on the box (DECISIONS.md entry 7) and `required: false`
  # makes its absence legal. It is recognised explicitly, and named here rather
  # than skipped silently, because silence would be indistinguishable from this
  # check failing to parse the line at all.
  if [[ "$line" =~ $ENV_FILE_ERE ]]; then
    continue
  fi

  fail "unrecognised ${APP_DATA_TOKEN} line shape in ${APP_ID}/docker-compose.yml: '${line}'. This check classifies short-form volume entries and long-form env_file path entries; anything else may declare a bind-mount source it cannot verify, so it fails rather than passing over it."
done

# A compose that references the token but declares no short-form volume leaves
# nothing for this check to assert on, which is the same fail-closed case as
# zero references.
if (( ${#host_subpaths[@]} == 0 )); then
  fail "no short-form ${APP_DATA_TOKEN} volume entry found in ${APP_ID}/docker-compose.yml — this check verified no bind-mount source. A mount named only in a comment or an env_file entry does not declare one."
fi

verified=()
for i in "${!host_subpaths[@]}"; do
  subpath="${host_subpaths[$i]}"
  source_line="${source_lines[$i]}"
  target="${repo_root}/${APP_ID}/${subpath}"

  if [[ ! -e "$target" ]]; then
    fail "bind-mount source not shipped: ${APP_ID}/docker-compose.yml declares '${source_line}' but ${APP_ID}/${subpath} does not exist in this repo. umbreld pre-creates a host-side app-data subdirectory only when the app template ships it, so Docker will create the source root:root at compose up — and the container (uid 1000, cap_drop: ALL, no-new-privileges:true) cannot write into a root-owned directory, so it crash-loops on every fresh install. Ship ${APP_ID}/${subpath} as a committed directory."
  fi

  if [[ ! -d "$target" ]]; then
    fail "bind-mount source is not a directory: ${APP_ID}/docker-compose.yml declares '${source_line}', and ${APP_ID}/${subpath} exists but is not a directory. A bind-mount source must be a directory in the app template; umbreld copies the template verbatim, so a file here is what the box would get."
  fi

  verified+=("${APP_ID}/${subpath}")
done

printf 'check-bind-mount-dirs: OK: every declared app-data bind-mount source is shipped: %s\n' "${verified[*]}"
