#!/usr/bin/env bash
#
# Fail when the compose file declares a host-side bind-mount source under
# ${APP_DATA_DIR} that this repo does not ship as a committed directory inside
# the app template.
#
# WHY A STORE REPO NEEDS THIS. This repo's app template is the only thing
# under this repo's control that determines what exists at a bind-mount
# source on a fresh install — umbreld's own install mechanism pre-creates a
# subdirectory only when the store ships it, and does nothing else to fix its
# ownership. A missing directory here is fatal for THIS app specifically: the
# container runs as uid 1000 under `cap_drop: ALL` + `no-new-privileges:true`
# (DECISIONS.md entry 6), so it cannot create its SQLite database inside a
# directory Docker would otherwise create root:root, and crash-loops on every
# fresh install (issue #8). The upstream install()/rsync mechanism that makes
# this true, why no on-box chown exists to fall back on, and the ecosystem
# sweep that confirmed the pattern are recorded ONCE, in DECISIONS.md entry
# 8 — read it there for the mechanism narrative and evidence rather than
# here; restating it here would create a second copy of citations that rot
# independently of that entry's.
#
# SCOPE. This check verifies what the compose file DECLARES against what this
# repo SHIPS. It parses two shapes: short-form volume entries
# (`- ${APP_DATA_DIR}/<host>:<container>`, unquoted or wrapped in matching
# double/single quotes, with an optional `:ro`/`:rw` mount-mode suffix) and
# long-form `env_file` path entries (`- path: ${APP_DATA_DIR}/<...>`), which
# name a file Compose reads rather than a bind-mount source Docker creates and
# are recognised but deliberately excluded from the directory assertion. It
# does not inspect an installed box, and it asserts nothing about ownership at
# runtime — ownership on the box is downstream of what this repo ships, and
# what this repo ships is the half under this repo's control.
#
# FAIL-CLOSED. A file that is missing, a line the check cannot classify, or a
# subpath that does not match the expected shape is a FAILURE, never a skip. A
# check that silently passes when it cannot read its inputs is worse than no
# check: it reports safety it never established.

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
# clear diagnostic rather than an empty-match error further down. Readability is
# checked separately from existence: an unreadable file would otherwise fall
# through to the zero-declared-lines check below and report a misleading "no
# declaration found" when the real cause is a permission problem.
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"
[[ -r "$compose" ]] || fail "compose file not readable at ${compose}"

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

# Shape 1 — short-form volume entry: `- ${APP_DATA_DIR}/<host>:<container>`,
# optionally wrapped in matching quotes around the WHOLE "host:container" pair
# and optionally suffixed with a trailing `:ro` / `:rw` mount mode. Capture
# group 1 is the host-side subpath: by construction the text between the
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
#
# Quote handling is an alternation of THREE WHOLE FORMS — unquoted, the pair
# wrapped in double quotes, the pair wrapped in single quotes — never two
# independently optional quote marks. check-version-drift.sh's own comment
# states why: `['\"]?VALUE['\"]?` would accept a MISMATCHED pair (e.g.
# `"${APP_DATA_DIR}/data:/data'`), which is not valid YAML, and POSIX ERE has no
# backreference to require the closing quote match the opening one. All three
# forms are legal Compose short-syntax volume entries and all three are common —
# a gate that blocks a valid quoted mount is as much a defect as one that misses
# a real drift.
readonly MOUNT_MODE_ERE='(:(ro|rw))?'
readonly VOLUME_ERE_UNQUOTED="${LIST_ITEM_ERE}${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}${TRAILING_ERE}"
readonly VOLUME_ERE_DQUOTED="${LIST_ITEM_ERE}\"${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}\"${TRAILING_ERE}"
readonly VOLUME_ERE_SQUOTED="${LIST_ITEM_ERE}'${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}'${TRAILING_ERE}"

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
  if [[ "$line" =~ $VOLUME_ERE_UNQUOTED ]] || [[ "$line" =~ $VOLUME_ERE_DQUOTED ]] || [[ "$line" =~ $VOLUME_ERE_SQUOTED ]]; then
    subpath="${BASH_REMATCH[1]}"
    if [[ ! "$subpath" =~ ^${SUBPATH_ERE}$ ]]; then
      fail "unusable host-side subpath '${subpath}' extracted from ${APP_ID}/docker-compose.yml line '${line}' — expected a relative path of name segments. A subpath this check cannot resolve to a repo path is a failure, not a skip."
    fi
    # `.` and `..` segments pass SUBPATH_ERE's character class (both characters
    # are in it) but are not name segments — they are relative-path navigation.
    # `${APP_DATA_DIR}/../evil/data` would otherwise validate and then be
    # concatenated into `target` below with no containment check, resolving
    # OUTSIDE this app's own directory. Reject any such segment explicitly
    # rather than relying on the character class to exclude it, so containment
    # holds regardless of how the path is spelled.
    IFS='/' read -r -a subpath_segments <<< "$subpath"
    for segment in "${subpath_segments[@]}"; do
      if [[ "$segment" == "." || "$segment" == ".." ]]; then
        fail "unusable host-side subpath '${subpath}' extracted from ${APP_ID}/docker-compose.yml line '${line}' — segment '${segment}' is a relative-path navigation component, not a name; it could resolve outside ${APP_ID}. A subpath this check cannot resolve safely to a repo path is a failure, not a skip."
      fi
    done
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

  # No component of the resolved bind-mount source — from the app template
  # directory itself down to the leaf — may be a symlink. `[[ -e ]]` and
  # `[[ -d ]]` below both FOLLOW symlinks, so accepting one would let a
  # symlinked component escape this app's directory even though the compose
  # STRING contains no traversal segment: `rsync --archive` (DECISIONS.md
  # entry 8) ships symlinks AS symlinks, so a symlink committed at or above
  # the bind-mount source reproduces on the box unchanged, and Docker
  # resolves it at mount time — handing the uid-1000, `cap_drop: ALL`
  # container a bind mount into whatever it points at. The leaf alone is not
  # sufficient: a nested subpath (a shape this check already accepts) escapes
  # just as well through an INTERMEDIATE component, and the app template
  # directory itself is not exempt either — `lstat` resolves intermediate
  # components transparently, so a symlinked `${APP_ID}` would make every
  # `-L` check on an appended segment report on whatever real entry sits
  # inside the symlink's target rather than on anything in this repo. So the
  # walk starts by checking the app directory ITSELF, before any subpath
  # segment is appended, and only then appends and checks each segment in
  # turn — every component from the app directory down to the leaf is
  # checked, including the starting point, and the offending one is named on
  # failure.
  check_path="${repo_root}/${APP_ID}"
  if [[ -L "$check_path" ]]; then
    fail "bind-mount source contains a symlink: ${APP_ID}/docker-compose.yml declares '${source_line}' but '${APP_ID}' is a symlink, not a real directory. rsync --archive ships symlinks verbatim, so a symlinked app template directory would hand the uid-1000, cap_drop: ALL container a bind mount into whatever the symlink resolves to on the host. Ship a real directory at ${APP_ID}."
  fi
  IFS='/' read -r -a target_segments <<< "$subpath"
  for segment in "${target_segments[@]}"; do
    check_path="${check_path}/${segment}"
    if [[ -L "$check_path" ]]; then
      fail "bind-mount source contains a symlink: ${APP_ID}/docker-compose.yml declares '${source_line}' but '${check_path#"${repo_root}/"}' is a symlink, not a real directory. rsync --archive ships symlinks verbatim, so a symlinked component here would hand the uid-1000, cap_drop: ALL container a bind mount into whatever the symlink resolves to on the host. Ship a real directory at every component of ${APP_ID}/${subpath}."
    fi
  done

  if [[ ! -e "$target" ]]; then
    fail "bind-mount source not shipped: ${APP_ID}/docker-compose.yml declares '${source_line}' but ${APP_ID}/${subpath} does not exist in this repo. umbreld pre-creates a host-side app-data subdirectory only when the app template ships it, so Docker will create the source root:root at compose up — and the container (uid 1000, cap_drop: ALL, no-new-privileges:true) cannot write into a root-owned directory, so it crash-loops on every fresh install. Ship ${APP_ID}/${subpath} as a committed directory."
  fi

  if [[ ! -d "$target" ]]; then
    fail "bind-mount source is not a directory: ${APP_ID}/docker-compose.yml declares '${source_line}', and ${APP_ID}/${subpath} exists but is not a directory. A bind-mount source must be a directory in the app template; umbreld copies the template verbatim, so a file here is what the box would get."
  fi

  verified+=("${APP_ID}/${subpath}")
done

printf 'check-bind-mount-dirs: OK: every declared app-data bind-mount source is shipped: %s\n' "${verified[*]}"
