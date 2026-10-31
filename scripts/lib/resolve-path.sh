# shellcheck shell=bash
# resolve-path.sh — the ONE shell definition of "the real absolute path a path
# names, every symlink followed" (INVARIANTS.md § Encapsulation rule 3).
#
# Sourcing this file defines one function and does nothing else: no trap, no
# global variable, no output. The callers below, outside the tests, are the
# codespace's; a managed repo holds this file as a byte-for-byte copy
# (cs#1969, cs#2015):
#   - scripts/lib/local-ci-parallel.sh sources it for the `parallel:` step's
#     containment check;
#   - scripts/lib/atomic-write.sh's write_file_atomically runs it in a
#     subshell, so a symlinked target is written through its link;
#   - .claude/hooks/scan-standards-read.sh sources it for the paths its
#     outside-the-repo exemption and repo-local DECISIONS.md check compare.
#
# Public function:
#   resolve_absolute <path>
#
# `readlink -f` and `realpath` are both banned per STANDARDS.md § Shell
# Portability Checklist (GNU-only / requires coreutils on macOS). `cd -P` +
# `pwd -P` resolves any symlinked DIRECTORY component in one step, but not a
# symlinked FINAL component, so the loop first follows the final component with
# plain POSIX `readlink` (present on GNU and BSD alike, unlike `readlink -f`)
# until it is no longer a symlink, for at most 40 links (a longer chain is
# treated as a cycle). The final component need not exist; its directory must.
# Prints the fully-resolved absolute path, or returns 1 on any resolution
# failure (a missing directory, a chain still a symlink after 40 links).

resolve_absolute() {
  local path="$1" dir target depth=0
  while [[ -L "$path" && "$depth" -lt 40 ]]; do
    target="$(readlink "$path")" || return 1
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      dir="$(dirname "$path")" || return 1
      path="$dir/$target"
    fi
    depth=$((depth + 1))
  done
  if [[ -L "$path" ]]; then
    return 1
  fi
  dir="$(dirname "$path")" || return 1
  local base resolved_dir
  base="$(basename "$path")" || return 1
  resolved_dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$resolved_dir" "$base"
}
