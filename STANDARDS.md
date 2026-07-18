# STANDARDS — miner-fleet-store

The canonical standards apply in full and are not restated here. The three
standards documents vendored into this repo's snapshot are:

- [`.engine-context/codespace/docs/oo-standards.md`](.engine-context/codespace/docs/oo-standards.md) — OO architecture
- [`.engine-context/codespace/docs/coding-standards.md`](.engine-context/codespace/docs/coding-standards.md) — filenames, identifier casing, shell scripting
- [`.engine-context/codespace/docs/hook-standards.md`](.engine-context/codespace/docs/hook-standards.md) — authoring rules for the canonical hook estate this repo symlinks in

`docs/testing-standards.md` is not part of the snapshot this repo vendors — the
snapshot's doc set is uniform across every managed repo in this estate, and no
repo vendors it, including repos that do have test suites. This repo now has one
(`tests/test-check-version-drift.sh`), and it is written to that document's rules
regardless: § 4.1 hermetic fixtures, cited in the file's own header. (§ 3.1
fail-closed stubs does not apply — it governs `FAKE_BIN` stubs of external CLIs,
and this suite stubs no CLI.) Read the canonical copy in the codespace repo when
editing it; it is named here so its absence from the list above reads as a
property of the snapshot rather than as an oversight.

Below are the repo-specific extensions only. Every rule here carries a receipt; a
rule with no receipt does not belong in this file.

---

## Repo-specific extensions

None yet.

This is an honest empty section, not a placeholder. The repo now holds the store
manifest, the app manifest, the compose file, the icon, the operator runbook, and
a version-drift check with its tests — but shipping content is not the same as
having a repo-specific STYLE rule to write down. The canonical standards already
govern everything here: the shell scripts by `coding-standards.md` § 9, the test
fixtures by `testing-standards.md` § 4, the YAML by nothing beyond
Umbrel's own schema. No rule has been needed that the canonical set does not
already state, and no incident has occurred on this repo to write a receipt from.
Inventing rules ahead of a failure they would have prevented is exactly what the
canonical standards' scope discipline forbids.

The five constraints that DO bind this repo — store/app naming, networking mode,
image pinning, which digest to pin, and icon hosting — are permanent decisions
with recorded rationale, not style rules, so they live in
[`DECISIONS.md`](DECISIONS.md).

Extensions land here when a rule is genuinely needed, each with the run, PR, or
incident that motivated it.
