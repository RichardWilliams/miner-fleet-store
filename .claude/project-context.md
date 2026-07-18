# Project Context

This is `miner-fleet-store`: the Umbrel Community App Store that distributes
`miner-fleet` to the operator's own Umbrel Home box. It is a distribution
channel, not an application. Review it as release infrastructure — the questions
that matter are "does umbrelOS resolve this correctly?" and "is this safe to
publish to the world?", not "is this code well-factored", because there is
almost no code here to factor.

## What is actually in this repo

- **Declarative metadata only.** A store manifest, an app manifest, and a compose
  file. No application source, no `package.json`, no build step, no test runner,
  no TypeScript. A reviewer looking for unit tests or a type-check gate should
  expect to find none — that absence is the design, not a gap.
- **A machine consumer, not a human one.** umbrelOS's `umbreld` clones this repo
  over plain git and re-polls it on a short interval, parses the manifests, and
  reconciles the running container against them. Errors surface as an app that
  quietly fails to appear or fails to install, rarely as a readable message. A
  malformed field here is a silent production failure, which is why manifest
  correctness carries more weight than it would in a repo with a compiler.
- **Currently bootstrap only.** At the time of writing the repo holds a README
  and the managed-repo scaffolding. The store manifest, the app directory, and
  the compose file do not exist yet, and the image pin they will carry depends on
  `miner-fleet` cutting a real semver release first. Do not review their absence
  as an omission.

## The world-readable constraint dominates everything

This repo is public and cannot become private: `umbreld` clones it with no
credentials, so a private store is not installable. Every commit is a permanent
publication.

Weight privacy findings accordingly. A LAN IP address, a hostname, a MAC address,
anything that geolocates the deployment, any credential, or any value that
fingerprints the fleet (unit counts, serial numbers, per-device identifiers) is a
blocking finding here even when the same value would be a minor note in a private
repo. Installation-specific values belong in Umbrel's app configuration, supplied
by the operator at install time.

## Review posture

- **Give strong opinions.** Challenge naming, challenge the compose shape,
  challenge whether a decision recorded in `DECISIONS.md` still holds given what
  the diff actually does. Surface what is worth considering; the operator decides
  what to act on.
- **Check the diff against `DECISIONS.md` literally.** Store/app naming,
  networking mode, and image pinning are settled decisions with recorded
  rationale. A diff that contradicts one is a finding regardless of whether the
  contradiction looks reasonable in isolation — the decision, or the diff, has to
  change, and the decision entry names the conditions for revisiting it.
- **Security scrutiny scoped to the real surface.** The exposure here is what
  gets published (privacy) and what the compose file grants the container
  (capabilities, mounts, network mode, exposed ports). Application-level
  vulnerability classes have no code here to live in.
- **Single-operator home lab.** Multi-tenancy, rate limiting, and SLA findings
  are unlikely to apply. Raise a genuine concern anyway if you see one; use
  judgement rather than a blanket suppression.
