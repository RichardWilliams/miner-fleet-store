# STANDARDS — miner-fleet-store

The canonical standards apply in full and are not restated here. The three
standards documents vendored into this repo's snapshot are:

- [`.engine-context/codespace/docs/oo-standards.md`](.engine-context/codespace/docs/oo-standards.md) — OO architecture
- [`.engine-context/codespace/docs/coding-standards.md`](.engine-context/codespace/docs/coding-standards.md) — filenames, identifier casing, shell scripting
- [`.engine-context/codespace/docs/hook-standards.md`](.engine-context/codespace/docs/hook-standards.md) — authoring rules for the canonical hook estate this repo symlinks in

`docs/testing-standards.md` is not part of the snapshot this repo vendors, and
this repo has no test suite for it to govern; it is named here only so its
absence from the list above reads as deliberate rather than as an oversight.

Below are the repo-specific extensions only. Every rule here carries a receipt; a
rule with no receipt does not belong in this file.

---

## Repo-specific extensions

None yet.

This is an honest empty section, not a placeholder. The repo currently holds a
README and this managed-repo scaffolding — no store manifest, no app manifest, no
compose file. There is no shipped artifact for a repo-specific rule to constrain,
and no incident on this repo to write a receipt from. Inventing rules ahead of
the code they would govern is exactly what the canonical standards' scope
discipline forbids.

The three constraints that DO already bind this repo — store/app naming,
networking mode, and image pinning — are permanent decisions with recorded
rationale, not style rules, so they live in [`DECISIONS.md`](DECISIONS.md).

Extensions land here as the store content lands, each with the run, PR, or
incident that motivated it.
