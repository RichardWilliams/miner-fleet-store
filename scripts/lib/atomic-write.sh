# shellcheck shell=bash
# atomic-write.sh — the ONE shell definition of "replace a file's content so
# no reader ever sees it part-written" (INVARIANTS.md § Encapsulation rule 3).
#
# Sourcing this file defines one function and does nothing else: no trap, no
# global variable, no output. Each managed repo carries a byte-for-byte copy
# of the codespace's file (cs#1969); in the codespace, its callers outside the
# tests are (cs#2015):
#   - .devcontainer/post-start.sh's write_shell_init_file runs it as root
#     (`sudo bash -c`) for the shell-init files it writes;
#   - scripts/setup-repo.sh's sync_gitignore, for a repo's .gitignore, after
#     refusing a symlinked .gitignore itself;
#   - scripts/memory-curate.sh's _write_memory_index, for MEMORY.md;
#   - scripts/sync-settings.sh's generate mode, for .claude/settings.json;
#   - scripts/lib/worktree-context.sh's write_worktree_context, for the
#     worktree-context stamp, in a subshell so its own sourcers do not gain
#     the function;
#   - scripts/check-decisions-index.sh --write, for DECISIONS.md;
#   - scripts/lib/canonical-copies.sh's canonical_copies_write, for the
#     canonical copies the sync writes into a managed repo.
#
# Public function:
#   write_file_atomically <target> <mode> <content>
#
# Writes <content> (an argument, so every caller has built it before the
# write starts) to a temporary file `.<name>.XXXXXX` in the target's
# own directory, then renames it over the target. A symlinked target is
# resolved first (resolve_absolute, scripts/lib/resolve-path.sh, run in a
# subshell so sourcing this file still defines nothing else) and the real file
# is written, so the link stays a link.
#
# <mode> is the target's mode after the write, in octal, or `-` to keep an
# existing target's mode. An existing target's mode (when `-`) and, for a root
# caller, its owner are carried onto the temporary file with `cp -p` (portable;
# `stat -c` is not). A new target written with `-` gets 0666 less the umask,
# what a plain redirect would give it.
#
# On any failure the target is byte-unchanged, the error names it and the
# function returns non-zero. The body runs in its own subshell, whose EXIT trap
# removes the temporary file on every path out once mktemp has returned its
# name (a failure, or an INT or TERM, which exit 130 and 143). A signal in the
# instant between mktemp creating the file and the shell assigning its name
# can leave that one file behind. The traps live in that subshell only: a
# caller's own traps are untouched.

write_file_atomically() (
  local target mode="$2" content="$3" tmp=""
  trap 'if [[ -n "${tmp}" ]]; then rm -f "${tmp}"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! target="$(. "$(dirname "${BASH_SOURCE[0]}")/resolve-path.sh" && resolve_absolute "$1")"; then
    echo "ERROR: could not resolve the real path of $1; it is left unchanged." >&2
    return 1
  fi
  if ! tmp="$(mktemp "$(dirname "${target}")/.$(basename "${target}").XXXXXX")"; then
    tmp=""
    echo "ERROR: could not create a temporary file beside ${target}; it is left unchanged." >&2
    return 1
  fi
  if [[ -e "${target}" ]]; then
    if ! cp -p "${target}" "${tmp}"; then
      echo "ERROR: could not copy the mode and owner of ${target}; it is left unchanged." >&2
      return 1
    fi
  elif [[ "${mode}" == "-" ]]; then
    mode="$(printf '%o' "$(( 0666 & ~$(umask) ))")"
  fi
  if { [[ "${mode}" == "-" ]] || chmod "${mode}" "${tmp}"; } \
    && printf '%s' "${content}" > "${tmp}" \
    && mv -f "${tmp}" "${target}"; then
    tmp=""
    return 0
  fi
  echo "ERROR: writing ${target} failed; it is left unchanged." >&2
  return 1
)
