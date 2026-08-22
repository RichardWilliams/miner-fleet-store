#!/usr/bin/env bash
#
# Shared harness for this repo's bash check suites. It owns the scratch
# directory every fixture is built under, the single cleanup trap, the pass/fail
# counters, the case runner, and the summary line.
#
# It knows nothing about any individual check: `assert_case` takes the command
# to run as trailing arguments, so each suite resolves its own script under test
# and builds its own check-specific fixtures.
#
# SOURCE this file, never execute it — the scratch dir and the traps have to
# belong to the suite's own process.

# ONE cleanup handler for the suite process (codespace docs/coding-standards.md
# § 9.3 — a second `trap ... EXIT` at this scope would silently replace it).
# INT and TERM exit rather than clean up themselves, so the single EXIT handler
# is the only thing that removes the scratch dir.
scratch=""
cleanup() {
  [[ -n "$scratch" && -d "$scratch" ]] && rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

scratch="$(mktemp -d)"

failures=0
passes=0

# $1 = case description, $2 = expected exit (0 pass / 1 fail), $3 = substring
# expected in the combined output (empty to skip), $4... = the command to run.
assert_case() {
  local desc="$1" expected="$2" expect_substr="$3"
  shift 3
  local out="" rc=0
  out="$("$@" 2>&1)" || rc=$?

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

# redeclare_vendor_dir_name <fixture-context-lib> <prefix> — rewrite the ONE
# declaration of the vendored artefact directory name inside a fixture's own
# copy of scripts/lib/repo-context.sh.
#
# It exists so a case can require the script under test to FOLLOW the
# declaration rather than a spelling of its own. `vendor_dir_name` is compared
# against a directory found on disk as well as used to build the paths inside
# it, so a join re-inlined at any ONE of those sites leaves every fixture that
# spells the name the current way green — the drift would be invisible until a
# release read the wrong artefacts. A fixture that redeclares the name goes red
# the moment a site stops following it.
#
# This is repo-context knowledge shared by three suites rather than knowledge of
# any one check, which is why it lives beside the other shared machinery instead
# of being written out three times.
#
# A rewrite that matched nothing would turn every case built on it into a case
# that asserts nothing, so a marker that is not present exactly once is FATAL.
redeclare_vendor_dir_name() {
  local lib="$1" prefix="$2"
  local marker="printf 'v%s'"
  local occurrences=0
  occurrences="$(grep -cF "$marker" "$lib" || true)"
  if (( occurrences != 1 )); then
    printf 'FATAL: expected exactly one %q in %s, found %d\n' "$marker" "$lib" "$occurrences" >&2
    exit 1
  fi
  # A temp file plus a copy back, rather than `sed -i`, which is a GNU
  # extension.
  local rewritten="${lib}.redeclared"
  sed "s|printf 'v%s'|printf '${prefix}%s'|" "$lib" > "$rewritten"
  cat "$rewritten" > "$lib"
  rm -f "$rewritten"
}

# Last statement of every suite: print the tally and exit non-zero on failures.
report_summary() {
  printf '\n%d passed, %d failed\n' "$passes" "$failures"
  (( failures == 0 )) || exit 1
}
