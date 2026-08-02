#!/usr/bin/env bash
#
# Fail when the compose file declares a host-side bind-mount source under
# ${APP_DATA_DIR} that this repo does not ship as a committed directory inside
# the app template. FAIL-CLOSED: a missing or unreadable file, an unclassifiable
# line, or a subpath of an unexpected shape is a FAILURE, never a skip — a check
# that passes when it cannot read its inputs reports safety it never established.
#
# SCOPE. What the compose file DECLARES against what this repo SHIPS. Two shapes
# are parsed: short-form volume entries (`- ${APP_DATA_DIR}/<host>:<container>`,
# unquoted or in matching double/single quotes, optional `:ro`/`:rw` mount-mode
# suffix), and long-form `env_file` path entries (`- path: ${APP_DATA_DIR}/<...>`),
# which name a file Compose reads rather than a bind-mount source Docker creates
# and are recognised but excluded. Mechanism and evidence: DECISIONS.md entry 8.

set -euo pipefail

# Resolved from this script's own location, so the check runs from anywhere.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

readonly APP_ID="pipfox-miner-fleet"
compose="${repo_root}/${APP_ID}/docker-compose.yml"

# fail() is shared with the sibling gates — see scripts/lib/check-common.sh.
source "${script_dir}/lib/check-common.sh"

# Guard order: existence, then readability, before any parsing — so a permission
# problem names its real cause instead of falling through to the branch below.
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"
[[ -r "$compose" ]] || fail "compose file not readable at ${compose}"

# The literal token, for the `grep -F` collection and for diagnostics. The `$` is
# escaped so bash yields the token itself, not the value of a variable by that name.
readonly APP_DATA_TOKEN="\${APP_DATA_DIR}"

# POSIX ERE only — no \d, \s or \b (INVARIANTS.md § Tool invocation correctness).
# `$`/`{`/`}` are escaped metacharacters; negated brackets put `:` AFTER the class
# (`[^[:space:]:]`) so `[:` cannot start a class name.
readonly APP_DATA_ERE='\$\{APP_DATA_DIR\}'
readonly LIST_ITEM_ERE='^[[:space:]]*-[[:space:]]+'
readonly TRAILING_ERE='[[:space:]]*(#.*)?$'
readonly SUBPATH_ERE='[[:alnum:]._-]+(/[[:alnum:]._-]+)*'
readonly COMMENT_LINE_ERE='^[[:space:]]*#'

# Shape 1 — short-form volume entry; capture group 1 is the host-side subpath.
# Extraction is BY CAPTURE GROUP on the anchored match, never by stripping a greedy
# `.*` prefix, because a greedy strip reads through to the LAST match on the line
# and would take the value out of a trailing comment; the sibling
# check-version-drift.sh shipped that defect and produced a false PASS on real
# drift. Quote handling enumerates three whole forms because POSIX ERE has no
# backreference, so `['\"]?VALUE['\"]?` would accept a mismatched pair.
readonly MOUNT_MODE_ERE='(:(ro|rw))?'
readonly VOLUME_ERE_UNQUOTED="${LIST_ITEM_ERE}${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}${TRAILING_ERE}"
readonly VOLUME_ERE_DQUOTED="${LIST_ITEM_ERE}\"${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}\"${TRAILING_ERE}"
readonly VOLUME_ERE_SQUOTED="${LIST_ITEM_ERE}'${APP_DATA_ERE}/([^[:space:]:\"']*):(/[^[:space:]:\"']*)${MOUNT_MODE_ERE}'${TRAILING_ERE}"

# Shape 2 — long-form `env_file` path entry: `- path: ${APP_DATA_DIR}/<...>`.
readonly ENV_FILE_ERE="${LIST_ITEM_ERE}path:[[:space:]]+${APP_DATA_ERE}/[^[:space:]]+${TRAILING_ERE}"

# Whole-line YAML comments are excluded: a comment declares nothing, and must not
# be able to SATISFY the check either.
declared_lines=()
while IFS= read -r line; do
  if [[ "$line" =~ $COMMENT_LINE_ERE ]]; then
    continue
  fi
  declared_lines+=("$line")
done < <(grep -F "$APP_DATA_TOKEN" "$compose")

# Zero is a FAILURE: the file changed shape, or this script reads the wrong path.
if (( ${#declared_lines[@]} == 0 )); then
  fail "no ${APP_DATA_TOKEN} declaration found in ${compose} — the file declares no app-data path, so this check verified nothing. Either the file changed shape or this check is reading the wrong path."
fi

# Parallel arrays, so a failure downstream names the line a subpath came from.
host_subpaths=()
source_lines=()

for line in "${declared_lines[@]}"; do
  if [[ "$line" =~ $VOLUME_ERE_UNQUOTED ]] || [[ "$line" =~ $VOLUME_ERE_DQUOTED ]] || [[ "$line" =~ $VOLUME_ERE_SQUOTED ]]; then
    subpath="${BASH_REMATCH[1]}"
    if [[ ! "$subpath" =~ ^${SUBPATH_ERE}$ ]]; then
      fail "unusable host-side subpath '${subpath}' extracted from ${APP_ID}/docker-compose.yml line '${line}' — expected a relative path of name segments."
    fi
    # `.` and `..` pass SUBPATH_ERE's character class but are relative-path
    # navigation rather than name segments, so they are rejected explicitly.
    IFS='/' read -r -a subpath_segments <<< "$subpath"
    for segment in "${subpath_segments[@]}"; do
      if [[ "$segment" == "." || "$segment" == ".." ]]; then
        fail "unusable host-side subpath '${subpath}' extracted from ${APP_ID}/docker-compose.yml line '${line}' — segment '${segment}' is a relative-path navigation component, not a name, and could resolve outside ${APP_ID}."
      fi
    done
    host_subpaths+=("$subpath")
    source_lines+=("$line")
    continue
  fi

  # An `env_file` path names a FILE Compose READS, not a bind-mount source Docker
  # CREATES (DECISIONS.md entry 7), so it is excluded from the directory assertion
  # — recognised explicitly, because silence would be indistinguishable from
  # failing to parse the line at all.
  if [[ "$line" =~ $ENV_FILE_ERE ]]; then
    continue
  fi

  fail "unrecognised ${APP_DATA_TOKEN} line shape in ${APP_ID}/docker-compose.yml: '${line}'. This check classifies short-form volume entries and long-form env_file path entries; write the line as one of those."
done

# A token reference with no short-form volume leaves nothing to assert on.
if (( ${#host_subpaths[@]} == 0 )); then
  fail "no short-form ${APP_DATA_TOKEN} volume entry found in ${APP_ID}/docker-compose.yml — a mount named only in a comment or an env_file entry declares no bind-mount source."
fi

verified=()
for i in "${!host_subpaths[@]}"; do
  subpath="${host_subpaths[$i]}"
  source_line="${source_lines[$i]}"
  target="${repo_root}/${APP_ID}/${subpath}"

  # Every component is checked, the app template directory ITSELF included: `lstat`
  # resolves intermediate components transparently, so a symlinked ${APP_ID} would
  # make each `-L` test on an appended segment report on entries inside the
  # symlink's target rather than on this repo. `rsync --archive` (DECISIONS.md
  # entry 8) ships symlinks verbatim, so one committed here reaches the box intact.
  check_path="${repo_root}/${APP_ID}"
  if [[ -L "$check_path" ]]; then
    fail "bind-mount source contains a symlink: ${APP_ID}/docker-compose.yml declares '${source_line}' but '${APP_ID}' is a symlink, not a real directory. Ship a real directory at ${APP_ID}."
  fi
  IFS='/' read -r -a target_segments <<< "$subpath"
  for segment in "${target_segments[@]}"; do
    check_path="${check_path}/${segment}"
    if [[ -L "$check_path" ]]; then
      fail "bind-mount source contains a symlink: ${APP_ID}/docker-compose.yml declares '${source_line}' but '${check_path#"${repo_root}/"}' is a symlink, not a real directory. Ship a real directory at every component of ${APP_ID}/${subpath}."
    fi
  done

  if [[ ! -e "$target" ]]; then
    fail "bind-mount source not shipped: ${APP_ID}/docker-compose.yml declares '${source_line}' but ${APP_ID}/${subpath} does not exist in this repo. Docker creates the source root:root at compose up and the container cannot write into it (DECISIONS.md entry 8). Ship ${APP_ID}/${subpath} as a committed directory."
  fi

  if [[ ! -d "$target" ]]; then
    fail "bind-mount source is not a directory: ${APP_ID}/docker-compose.yml declares '${source_line}', and ${APP_ID}/${subpath} exists but is not a directory. Ship a directory there — umbreld copies the template verbatim."
  fi

  verified+=("${APP_ID}/${subpath}")
done

printf 'check-bind-mount-dirs: OK: every declared app-data bind-mount source is shipped: %s\n' "${verified[*]}"
