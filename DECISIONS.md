# DECISIONS

Permanent decisions for this repo. Each entry carries Statement / Why /
Revisit-if. Entries are appended as part of the originating PR that makes the
decision, atomic with the structural change that implements it (codespace
CLAUDE.md RULE #0).

Entries 1-3 transcribe decisions the operator settled while scoping the store
work, recorded in `miner-fleet-store#1`'s issue body; they were captured by the
bootstrap PR ahead of the structural change that implements them. Entries 4-5
are decisions made by `#1` itself — the PR that landed the manifests, the compose
file and the directory layout — and are appended by that PR, atomic with the
change, per codespace CLAUDE.md RULE #0. Entry 6's ownership claim was corrected,
and entry 8 appended, by the PR closing `#8` — the fix for a fresh-install
crash loop caused by that entry's original, unverified claim about who creates
and owns the bind-mount source. That same PR appended entry 9, recording the
gate it added to enforce the `server` service's hardening mechanically.

Entries 10-15 are appended by the PR closing `#11` — the PR that added the
release driver `scripts/release.sh` and the fail-closed gates beside it
(`scripts/check-release-notes-drift.sh`, `scripts/check-deploy-contract.sh`,
`scripts/check-secret-leak.sh`). They record, in order: where the listing's
release notes come from, how they are spelled, which direction the
compose-versus-contract relationship runs in, the single policy that keeps the
networked gates off the network, why the release-PR review exemption named in
`#11`'s scope is not built in this repo, and where the credential-leak control
lives and what it deliberately does not refuse.

---

## 1. Store id `pipfox`, app id `pipfox-miner-fleet`, app directory name equal to the app id, compose service named `server`

**Statement.** The store id is `pipfox`. The app id is `pipfox-miner-fleet`. The
app directory at the repo root is named `pipfox-miner-fleet` — byte-for-byte the
app id, with no suffix, no variation, and no separate display slug. The
application service in `docker-compose.yml` is named `server`, and `app_proxy`'s
`APP_HOST` is `pipfox-miner-fleet_server_1`. These four names are one identifier
chain: each derives from the one before it, so changing any name requires
updating everything downstream of it in the same commit — a store-id change
reaches all four, a service rename reaches only `APP_HOST`.

**Why.** umbrelOS imposes the first two links. An app id must be
prefixed with the id of the store that ships it, so the app cannot be called
`miner-fleet` while the store is called `pipfox` — umbreld will not resolve it.
And the app is located on disk by its id, so the directory name must equal the
app id exactly; a mismatch makes the app invisible to the store scan rather than
producing a diagnosable error. Because the store id feeds the app id and the app
id feeds the directory name, a partial rename leaves the store in a state that
looks correct in the diff and silently fails to install.

The service name is the fourth link in that same chain, and fails the same way.
Umbrel injects `app_proxy` — the reverse proxy and authentication layer in front
of the app — and it locates the application container by the compose-generated
name in `APP_HOST`. Compose derives that name from the project (the app id) and
the service, so `pipfox-miner-fleet_server_1` is only correct while the service
is literally named `server`. Rename the service, or change the app id without
updating `APP_HOST`, and the container starts healthy while the proxy in front of
it resolves nothing: the operator sees a gateway error in the browser and no
indication anywhere that the configuration is wrong.

**Revisit if.** umbrelOS drops the store-id prefix requirement, the
id-equals-directory-name requirement, or `app_proxy`'s `<app-id>_server_1`
host-resolution convention; or the operator retires the `pipfox` store identity
in favour of a different one. A store-identity change sits at the head of the
chain, so it moves all four names in a single commit.

---

## 2. The app runs on bridge networking, not `network_mode: host`

**Statement.** The app's compose service uses standard Docker bridge networking.
`network_mode: host` is not used.

**Why.** The functional requirement is that the container can reach arbitrary
miners on the operator's LAN over TCP/HTTP. A bridge-networked container already
does this — outbound connections to LAN addresses are routed normally, so a
sweep over the miners' HTTP API works without host networking. `network_mode:
host` buys exactly one additional capability: receiving broadcast and mDNS
traffic, which matters only for discovery-by-announcement. The fleet is
enumerated by sweeping a known address range instead, so that capability is not
needed. The cost of taking it anyway is concrete: Umbrel's `app_proxy` — which
provides the app's authentication layer and its reverse proxy — does not work for
a host-networked service, so choosing `network_mode: host` means giving up
authentication in front of the app.

**Revisit if.** Discovery genuinely requires broadcast or mDNS (a sweep over the
known range proves insufficient in practice), AND an authentication path that
does not depend on `app_proxy` is designed first. Both conditions must hold —
the second is not optional, because dropping `app_proxy` without a replacement
removes the only thing standing in front of the app.

---

## 3. The image is pinned by semver tag AND sha256 digest together

**Statement.** The image reference in the compose file carries both a semver tag
and a sha256 digest, in the form `<image>:<semver>@sha256:<digest>`. Three forms
are banned: `latest` (or any moving tag), a bare commit SHA as the tag, and a
digest with no tag beside it.

**Why.** The two identifiers do different jobs and neither substitutes for the
other. The digest is what makes a deployment reproducible — it names exactly one
image, so what umbreld pulls is what was tested, and a re-tagged upstream cannot
silently change what runs. The tag is what makes the deployment legible — a human
reading the compose file, or an operator deciding whether to accept an update,
needs to know which release this is; a bare digest is unreadable and a bare
commit SHA carries no ordering, so neither answers "is this newer than what I am
running". `latest` fails both jobs at once: it is neither reproducible nor
informative, and it turns every unrelated upstream push into an unrequested
deployment change. Together, tag-plus-digest gives a reference that a human can
read and a machine cannot misresolve.

**Revisit if.** umbrelOS's manifest format stops accepting a combined
tag-and-digest reference, or a release process is adopted that provides an
equally reproducible and equally legible identifier — the requirement is the pair
of properties, not this particular syntax.

---

## 4. The pinned digest is the multi-arch INDEX digest, not a per-platform manifest digest

**Statement.** The `@sha256:` value in `docker-compose.yml` is the digest of the
multi-arch image INDEX — the value on the `Digest:` line of
`docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z`. It
is NOT any of the per-platform manifest digests listed underneath it in that
command's `Manifests:` section. DEPLOY.md § 3 step 1 states which line to read.

**Why.** Both values are valid 64-hex digests and both are immutable, so nothing
about the syntax distinguishes them and no check catches the wrong one: a
per-platform digest is *silently correct today and silently wrong the moment the
index changes*. umbreld resolves the index and selects the platform entry from
it, so pinning an inner manifest bypasses that selection and couples the store to
one specific platform build. Today the index contains exactly one real platform
(`linux/amd64`, entry 4) plus an attestation manifest, which is precisely what
makes the mistake invisible — the wrong pin would deploy correctly right up until
the release that adds or changes a platform, at which point it breaks with no
diff to explain it.

The distinction is a CORRECTNESS property, not a security one. Both forms are
equally immutable content-addressable pins; the security review confirmed the
supply-chain guarantee is identical either way. What differs is whether umbreld
can still resolve the right artefact after the index changes.

**Revisit if.** umbreld changes how it resolves image references (verify against
its source, not by observing that a deployment happened to work), or the image
stops being published as a multi-arch index, or miner-fleet's runtime image stops
carrying `node` with a global `fetch` — the compose healthcheck shells out to
both, an assumption that lives in the sibling repo's Dockerfile and nothing here
guards.

---

## 5. The app icon is self-hosted in this repo and referenced by its raw URL

**Statement.** The icon asset is committed at `pipfox-miner-fleet/icon.svg` and
`umbrel-app.yml`'s `icon:` field points at this repo's own
`raw.githubusercontent.com` URL on the `main` ref. It is NOT hosted on a
third-party image host such as svgur or imgur, and the URL is deliberately NOT
pinned to a commit SHA.

**Why.** Umbrel renders the tile from an https URL, and a community-store app
directory holds only the two YAML files, so the icon must be hosted somewhere.
Self-hosting keeps it versioned with the manifest that references it and puts no
third party in the dashboard's render path.

The `main` ref is a deliberate exception to entry 3's pinning discipline, on
mechanical grounds: a commit-SHA-pinned icon URL cannot be authored in the commit
that introduces the icon, and squash-merge destroys the branch SHA, so it could
only be set by a post-merge edit. The risk it would remove — a hostile icon
force-pushed over `main` — already requires write access to this repo, at which
point the `icon:` field is equally rewritable. Entry 3's digest pin is different
in kind: it defends against a compromised registry credential with no git access.
`gallery` entries follow this same rule.

**Revisit if.** Umbrel supports a directory-relative icon path, or this repo
takes external contributors — at which point `main` is no longer operator-only
and the trade-off changes shape.

---

## 6. Persistent state is a `${APP_DATA_DIR}/data:/data` bind mount, declared with the release that writes to it

**Statement.** The `server` service mounts `${APP_DATA_DIR}/data` onto the
container's `/data` — the app's default `MINER_FLEET_DATA_DIR`. The mount is
declared in the same store release that pins the first image which writes to
disk (miner-fleet `0.2.0`), never before and never after it.

**Why.** miner-fleet `0.2.0` persists its discovered inventory and telemetry
samples to a SQLite database under its data directory; without a declared volume
umbreld replaces the container on every version bump and that state is destroyed,
with the symptom (inventory empties after an update) sitting far from the cause
(no volume). `${APP_DATA_DIR}/data:/data` is the documented, shipped Umbrel
pattern — `${APP_DATA_DIR}` is the host-side app-data directory umbreld exports
into the compose environment. That contract — the `export APP_DATA_DIR`, its
`${UMBREL_ROOT}/app-data/${app}` value, and the `MINER_FLEET_DATA_DIR` = `/data`
default it feeds — is established and cited in the SIBLING repo (miner-fleet
`DECISIONS.md` entry 12 and `src/config/runtimeConfig.ts`), which owns it. This
store relies on that citation rather than re-deriving a second set of upstream
`file:line`s: those line numbers drift with every upstream commit (the
`legacy-compat/app-script` export/build lines have already moved across umbreld
releases), so pinning them here only creates a third copy to rot. The directory
**survives app updates and is removed only on uninstall**: umbreld's update copies
the app files (including this `docker-compose.yml`, so a new `volumes:` / `env_file:`
lands) over an explicit whitelist that never includes the `data/` subdirectory, and
uninstall removes the whole data directory via `app.ts`'s
`fse.remove(this.dataDirectory)`. The shipped precedent is vaultwarden's
`${APP_DATA_DIR}/data:/data`. An earlier version of this entry cited
vaultwarden's `user: "1000:1000"` line as the reason that mount is writable —
that was wrong and shipped a fresh-install crash loop (`#8`): `user:` governs
which uid the CONTAINER runs as and has no bearing on how Docker creates a
MISSING bind-mount source on the HOST side. What actually makes vaultwarden's
mount (and this app's) writable on a fresh install, the falsification-sweep
evidence behind it, and the mechanical check that now enforces it are recorded
once, in full, in DECISIONS.md entry 8 — this entry defers to it rather than
re-deriving the same mechanism a second time.

The ORDERING is the load-bearing half: the volume and the disk-writing image ship
together. Volume-first (before the writing image) declares storage nothing uses;
image-first (before the volume) resets the operator's data on every update until
the volume lands. So both move in one release.

**Revisit if.** umbrelOS changes where app-data lives or how it is preserved
across updates (verify against its source, not by observing a deployment), or the
app's container-side data directory moves off `/data`.

---

## 7. Operator runtime configuration is read from a data-volume env file the operator creates, never committed here

**Statement.** Per-install runtime configuration whose value is environment- or
operator-specific — first and foremost `MINER_FLEET_SUBNETS`, the LAN range(s) to
sweep — is delivered to the container via
`env_file: [{ path: ${APP_DATA_DIR}/data/config.env, required: false }]` on the
`server` service. The file is created BY THE OPERATOR on the box, inside the
persistent data volume. This repo commits the `env_file` REFERENCE only; it never
commits a real subnet, IP, hostname, MAC, or any other environment-specific value.

**Why.** This repo is PUBLIC and umbreld clones it unauthenticated, so a real LAN
range in any committed file is a codespace RULE #1 leak. The value must therefore
come from the box — and it must SURVIVE app updates, or the operator re-enters it
every release. Three facts force this exact shape:

- The app reads `MINER_FLEET_SUBNETS` from its process environment
  (miner-fleet `src/config/runtimeConfig.ts`), and when it is unset auto-derives
  the range from the container's own address — which on Umbrel is the docker
  app-network, not the operator's LAN, so the fleet is empty until it is set.
- umbreld passes a community-app compose NO `--env-file` and exports no custom
  vars (`getumbrel/umbrel` legacy-compat/app-script — the `docker compose`
  invocation carries no `--env-file`; only `APP_DATA_DIR`/`APP_ID`-class vars are
  exported). So a value reaches the container only as a literal in this compose
  or via an `env_file` this compose names.
- A literal here either commits the range (RULE #1) or is wiped on every update,
  because umbreld replaces this compose file on update while preserving the data
  directory (entry 6).

`env_file` pointing INTO the data volume satisfies all three: `${APP_DATA_DIR}` is
interpolated by compose from umbreld's exported environment, the file lives in the
update-surviving data dir, and nothing real is committed. `required: false` lets a
fresh install with no file yet start cleanly (empty fleet) rather than failing on
a missing env file.

The long-form `env_file` entry carrying a `required:` key is a Docker Compose
Specification feature added in **Docker Compose v2.24.0 (2024-01)**. This is a hard
REQUIREMENT of the mechanism, not a nicety: an older Compose rejects the syntax and
the container fails to start on every install and update — strictly worse than the
"empty fleet until configured" state `required: false` exists to avoid. It is
stated here as a checkable requirement, NOT an assumption about what umbrelOS
bundles: current umbrelOS (1.x) ships a Docker Compose well past 2.24, and
DEPLOY.md § 6 has the operator confirm `docker compose version` ≥ 2.24 on their own
box before relying on it (the failure, if their Compose is older, is a loud
install-time parse error, not a silent empty fleet). No shipped `getumbrel/umbrel-apps`
app was found using this long-form syntax, so the version floor is asserted from
the Compose changelog, not from an in-ecosystem precedent.

This supersedes the configuration-surface approach originally scoped in `#5`'s
issue body (an in-app settings UI persisted to the volume): the shipped `0.2.0`
image has no such UI and reads configuration only from the environment, so the
env-file mechanism is what actually works against the image being released.

**Revisit if.** miner-fleet gains an in-app settings surface that persists
configuration to the data volume and reads it at runtime (at which point the
subnet moves there and this entry is reconsidered), or umbrelOS gains a native
per-app settings mechanism that survives updates, or umbreld begins passing a
persistent `--env-file` to community-app compose.

---

## 8. The app template ships `data/.gitkeep`; the bind-mount source is never created by an on-box hook

**Statement.** `pipfox-miner-fleet/data/.gitkeep` is a committed, empty file. Its
sole purpose is to force git — and, downstream, this repo's rsync-based app
template — to carry a `data/` directory alongside `docker-compose.yml`, so that
`${APP_DATA_DIR}/data` (entry 6's bind-mount source) exists, owned `1000:1000`,
before the `server` container ever starts. No on-box script, hook, or chown is
used to create or fix the ownership of this directory.

**Why.** `getumbrel/umbrel` apps.ts `install()` materialises a fresh install's
app-data directory by `rsync --archive --exclude ".gitkeep" <template>/.
<app-data-dir>` and does nothing else to it — it does not pre-create arbitrary
subdirectories, and it has no chown for this app's data path. So a subdirectory
a compose file declares as a bind-mount source exists after install if and only
if the store repo ships it inside the app template; otherwise Docker creates it
`root:root` at `compose up`, and the hardened container (uid 1000, `cap_drop:
ALL`, `no-new-privileges:true`) cannot write into it — `SQLITE_CANTOPEN`
(errcode 14), crash loop, on every fresh install. This was verified, not
assumed: a falsification sweep of `getumbrel/umbrel-apps` found 332 of 333 apps
mounting `${APP_DATA_DIR}/data` ship a committed `data/.gitkeep`, matching this
mechanism. Re-derivable method, run 2026-08-02: shallow-clone
`getumbrel/umbrel-apps`, select every app directory whose `docker-compose.yml`
declares an `${APP_DATA_DIR}/data` bind mount, and check whether that same app
directory ships a committed `data/` directory. `scripts/check-bind-mount-dirs.sh`
now enforces the invariant mechanically — this entry records the choice among
the alternatives that mechanism forecloses:

- **(a) Mount `${APP_DATA_DIR}` itself as `/data`, rather than the `data`
  subdirectory beneath it — REJECTED.** It would work: the app-data root is the
  directory umbreld itself creates and owns, so it is writable with no
  extra step. It is rejected because `${APP_DATA_DIR}` also holds
  `docker-compose.yml` and `umbrel-app.yml` — the exact files umbreld reads to
  run this app — so mounting the root exposes umbreld's own control files to a
  writable mount inside the container. A compromised container could rewrite
  its own compose file or manifest and escalate on the app's next restart. The
  `data` subdirectory carries no such file, so mounting only it keeps the
  container's write access scoped to state it actually owns.
- **(b) A `hooks/pre-start` script doing `mkdir -p` + `chown -R 1000:1000` on
  the box — REJECTED.** This is a real, shipped upstream pattern — the single
  exception in the 333-app sweep (`file-drop`) uses exactly this — and it has a
  genuine advantage a committed directory does not: it would SELF-HEAL an
  existing box already caught by this bug, where a static `data/.gitkeep`
  cannot retroactively fix a `root:root` directory Docker already created. It
  is rejected anyway because it hands umbreld a host-side script that this
  PUBLIC repo would run AS ROOT on every app start, which cuts directly against
  the hardening posture the rest of this file establishes (digest pinning,
  `cap_drop: ALL`, `no-new-privileges:true`) — for the sake of repairing an
  install base of roughly one box, which a documented one-off `chown`
  (DEPLOY.md § 4) already recovers without any code running on the box at all.

No `version` bump accompanies this fix. `data/` is not in umbreld's
`legacy-compat/app-script` update whitelist
(`UPDATE_FILES_WHITELIST_PRE`/`_POST`), so an app UPDATE never touches it —
bumping `version` would deliver nothing to an already-broken box, while also
obligating a content-identical `0.2.1` miner-fleet image re-release purely to
keep `scripts/check-version-drift.sh` green. A fresh install or a reinstall
rsyncs whatever this repo currently holds, so it gets the fix with no version
change at all; an already-broken box is repaired by the manual `chown` in
DEPLOY.md § 4, not by an update. The `chown` and a reinstall are not
equivalent-cost recoveries for a box that already has state: `chown` preserves
it, while `reinstall` runs `uninstall` first, and `uninstall` removes the whole
app-data directory (`app.ts`: `fse.remove(this.dataDirectory)`) — destroying the
inventory/telemetry SQLite history and the operator's `config.env` (entry 7)
before `install` re-creates it from the template. DEPLOY.md § 4 states this.

**Revisit if.** umbreld starts pre-creating declared bind-mount sources itself
(verify against its source, not by observing a deployment that happened to
work), or the install base grows past the point where a documented one-off
`chown` is a reasonable recovery for an already-broken box, or umbrelOS gains a
first-class per-app data-permission mechanism that makes either rejected option
above safe to adopt.

---

## 9. The `server` service's hardening is enforced mechanically, not by inspection

**Statement.** `scripts/check-compose-hardening.sh` asserts, on the `server`
service alone, that `cap_drop:` contains `ALL`, that `security_opt:` contains
`no-new-privileges:true`, that no `network_mode: host` is declared, and that no
host `ports:` are published. It runs in `.local-ci.yml`, so the push gate and CI
execute it identically. It fails closed on anything it cannot parse.

**Why.** Entries 2 and 6 already record this hardening as a decision, but a
decision recorded in prose is only checked when someone reads the file. The PR
that added this gate verified the property by inspection — every compose line it
changed was a comment, so nothing about the `server` service moved — and that
inspection covers exactly one reading of one diff. It does not survive the next
one. A later edit that drops `cap_drop:` while rewording the prose around it
produces a container that still starts, still passes the version-drift and
bind-mount gates, and silently runs with full capabilities on the operator's box.
The assertion is scoped to `server` because `app_proxy` is Umbrel's injected
reverse-proxy: a directive found there says nothing about the container that runs
the app, so a whole-file match would report safety it never established.

**Revisit if.** umbrelOS stops fronting community apps with `app_proxy` (which is
what makes a published host port unnecessary), or the app acquires a genuine need
for host networking or a retained capability. In either case entries 1, 2 or 6
change first and this gate follows them — the gate is downstream of those
decisions, never the reason to keep one.

---

## 10. `releaseNotes` is the upstream GitHub Release body, never authored here

**Statement.** `pipfox-miner-fleet/umbrel-app.yml`'s `releaseNotes` is a copy of
the `RichardWilliams/miner-fleet` GitHub Release body for the version being
pinned. It is fetched by `scripts/release.sh`, vendored at
`upstream/vX.Y.Z/release-notes.txt`, and written into the manifest from that
file. It is never composed here, never edited here, and never partially
rewritten here. A missing Release, an empty body, or a `gh` failure stops the
release; there is no fall-through to hand-written text.

**Why.** The narrative an operator reads has exactly one author, upstream, where
the change was actually made. Writing it a second time in a packaging manifest
produces two copies of the same operator-facing text with nothing tying them
together — and the copy drifts silently, because nothing about a stale listing
looks wrong. The hard failure is the load-bearing half: a release that could
quietly proceed on hand-written notes would restore exactly the second-original
problem the first sentence removes, on precisely the releases where somebody was
in a hurry. `scripts/check-release-notes-drift.sh` makes the copy checkable at
push time, so the rule survives the next release rather than resting on whoever
cuts it remembering this entry.

**Revisit if.** umbrelOS gains a listing field whose content genuinely has no
upstream equivalent — packaging-only guidance an application Release could not
sensibly carry — at which point that field is a NEW field with its own source,
and `releaseNotes` still comes from the Release. Or miner-fleet stops publishing
GitHub Releases, in which case the authoritative home for the narrative moves and
this entry names its new location before any listing text is written by hand.

---

## 11. `releaseNotes` is plain prose with no markdown

**Statement.** The release-notes text carries no markdown syntax: no `**`, no
`[text](url)` links, and no line beginning with `#`. URLs are spelled out in
prose and lists are written as literal indented `  - ` lines.
`scripts/release.sh` refuses a body containing any of the three, naming the
reason, rather than writing it into the manifest.

**Why.** This is a verified property of umbrelOS, not a style preference.
`getumbrel/umbrel`'s `packages/ui/src/components/markdown.tsx` short-circuits
when the current path starts with `/community-app-store`: it returns the raw
string in a plain `whitespace-pre-line` div and bypasses react-markdown
entirely. A community app's detail page is served under exactly that path, so on
this app's own store page `**bold**` renders as literal asterisks, a link
renders as literal brackets and parens, and `## H` renders as literal hashes.

The split is what forces the rule rather than merely suggesting it.
`packages/ui/src/modules/app-store/updates-dialog.tsx` renders `releaseNotes`
through the SAME component, but the branch keys on the CURRENT route — so opened
from outside `/community-app-store` the same string DOES render as markdown. One
string, two surfaces, two results. Plain prose is the only spelling that is
correct on both, and it is what the shipped first-party manifests (immich, n8n,
home-assistant, vaultwarden, transmission, jellyfin, nextcloud) all use.

The corollary is worth stating because it is what makes plain prose readable
rather than a compromise: `whitespace-pre-line` PRESERVES newlines, so a `>-`
folded scalar's blank-line-separated paragraphs and more-indented bullet lines
render as intended on both surfaces.

**Revisit if.** The `isInCommunityAppStore` short-circuit is removed from
`markdown.tsx` upstream, or the community-store route stops matching it —
verified by reading that component's source, not by observing that one string
happened to render acceptably on one screen.

---

## 12. This repo ASSERTS the compose against the upstream deployment contract; it never generates it

**Statement.** `miner-fleet` publishes a generated `deploy/contract.json`
declaring the container port, the health path, the data-directory environment key
and its default, and the required environment keys.
`scripts/check-deploy-contract.sh` reads that contract at the PINNED tag and
asserts that `pipfox-miner-fleet/docker-compose.yml` still satisfies it. The
compose is never generated, templated, rewritten or emitted from the contract.
That direction is permanent.

The gate's unknown-field rule is scoped to the `packagingAffecting` subtree,
deliberately: an unrecognised field there is a failure naming the field, while
`documentation.*` and `nonPackagingAffecting.*` are ignored. That is not an
omission — a non-packaging-affecting fact never requires a coordinated store
bump, which is precisely what the upstream structural split exists to express,
and an unscoped reading would fail the gate on every run against the shipped
contract.

**Why.** The compose file is only half a description of the application. The
other half is Umbrel packaging contract: the injected `app_proxy` service, the
`<app-id>_server_1` `APP_HOST` naming rule (entry 1), `${APP_DATA_DIR}`
interpolation (entries 6 and 7), and the hardening entry 9 enforces. A generator
fed by an application-side contract cannot know any of that, so generating would
either drop it or require the contract to grow packaging knowledge that belongs
here. It would also flatten this file's explanatory comments, which are load-
bearing: they are the only place the `.gitkeep` mechanism, the digest-pinning
rule and the env-file reasoning are stated at the point of use.

Asserting keeps each fact owned where it is decided and still catches the drift.
Before the gate, three values upstream owns were hardcoded here with nothing
tying them to their source: an upstream rename of the health route, a container
port change, or a move of the data directory would have kept shipping stale
values and surfaced as a crash loop on the operator's box, with nothing in this
repo's diff to explain it — the same failure shape `#8` produced once already.

**Revisit if.** The Umbrel packaging surface this file carries moves somewhere
else entirely (umbrelOS stops injecting `app_proxy`, or gains a first-class
manifest field for the mount and the health probe), so that the compose file
becomes a pure restatement of application facts with no packaging knowledge of
its own. Generation is worth reconsidering at that point and not before.

---

## 13. Both networked gates read artefacts vendored at bump time, at the repo root

**Statement.** The two facts the new gates check — the upstream Release body and
the upstream deployment contract — are fetched ONCE, by `scripts/release.sh`, on
the machine cutting the release, and committed to this repo under
`upstream/vX.Y.Z/release-notes.txt` and `upstream/vX.Y.Z/contract.json`. Both
push-time gates are then purely textual comparisons against those committed
copies: no `gh`, no `docker`, no network call, at gate time, ever. This is ONE
policy covering BOTH gates, not two independent answers to the same question.

The vendored artefacts live at the REPO ROOT, deliberately not inside
`pipfox-miner-fleet/`. That directory is the Umbrel app template umbreld rsyncs
onto the operator's box; provenance artefacts have no business shipping there.

The directory name encodes the version, and the drift gate requires EXACTLY ONE
directory under `upstream/` whose name matches the manifest's own `version`.
That is the staleness guard, and it is what makes "fetched at the pinned tag,
never at main" mechanically checkable with no network at all:
`scripts/release.sh` removes the previous version's directory when it writes the
new one, so a bump that forgot to re-vendor, or a stale copy left beside a
current one, fails the gates closed.

**Why.** `scripts/check-version-drift.sh`'s header already states this repo's
convention: a push-time gate stays purely textual so it never fails on an
unavailable network. Both new gates needed a network read, so the convention had
to be honoured or abandoned — once, for both, rather than twice with two
different answers.

Vendoring honours it without weakening fail-closed. The alternative — calling the
network at gate time with a fail-closed network policy — is not available here,
and that is a fact rather than a preference: the pinned CI image
(`ghcr.io/richardwilliams/node-ci:v0.1.3`) carries bash, git, grep, sed, node and
python3, and carries neither `gh` nor `docker` nor a guaranteed network. A gate
built on a live fetch could only fail open in that container or block every run
in it. Vendoring moves the one networked read to the one place where the network
is genuinely available: the operator's machine, at bump time.

**What this does and does not buy — stated plainly.** The live verification
happens ONCE, in the driver, against the real Release and the real tagged tree.
Thereafter the gates assert that the committed copies and the manifest agree.
That is a WEAKER claim than a live re-fetch: it cannot detect an upstream Release
body edited after the bump, and it trusts that the vendored bytes were fetched by
the driver rather than hand-written. It is the deliberate price of a gate that
can never fail on an unavailable network, and the staleness guard above is what
keeps the weaker claim from decaying into no claim at all.

**Revisit if.** The pinned CI image gains `gh` and a guaranteed network AND a
live-fetch gate can be shown to fail closed on every network failure mode without
false-blocking correct work — both conditions, because either alone reintroduces
the failure this entry avoids. Or an upstream Release body is edited after a bump
and the divergence causes a real operator-visible problem, which would be the
receipt that the weaker claim above is not enough.

---

## 14. The release-PR review exemption gate is not built in this repo

**Statement.** `scripts/check-release-pr-scope.sh` — the mechanical, diff-derived
release-PR review exemption named in `#11`'s scope — is deliberately NOT built
here, and neither is `tests/test-check-release-pr-scope.sh`. The rule the
exemption was to express still holds and is recorded by this entry: a release-PR
review exemption is DIFF-DERIVED, never trust-based. No label, commit-message
marker, PR-body phrase or environment variable may ever grant one. The decision
this entry records is about WHERE that rule can be enforced, and the answer is
not "in this repo's tree".

**Why.** The gate would have no consumer. Reviewer-panel composition is resolved
entirely in the codespace estate, from the PR body and the closing issues, and
never from the managed repo's own files: `codespace/hook/reviewer_gate.py` and
`codespace/scan/reviewer_clean_push.py` read the expected panel exclusively from
the `## Review config` include lists on the PR body and on the issues it closes.
Neither reads this repo's tree at all. The codespace's own
`docs/architecture.md:106` states the same fact from the other side — "There is
no trigger config, canonical or local."

Composition is additive-only by the cs#1788 decision: a name is added to the
panel by a rule or by a named signal, and there is no subtractive counterpart for
a repo-local file to drive. So a gate shipped here would compute a correct
verdict that nothing reads, on every release PR, forever. That is a speculative
abstraction — a mechanism built for a consumer that does not exist — and
codespace `CLAUDE.md` RULE #5 refuses it. Building it and describing the gap in
the PR body instead would be the same refusal dressed as delivery.

This entry is the FIFTH of the five permanent decisions `#11`'s exp-119 requires
this PR to record; entries 10-13 carry the other four. What is not built is the
gate, not the rule — the diff-derived-never-trust-based statement above is the
record exp-119 asks for, and it is in the diff rather than in a PR body.

**Revisit if.** The codespace estate grows a consumer that reads a repo-local
exemption signal — a reviewer-gate path that consults the managed repo's tree
when composing or narrowing the panel. That is a change to the codespace
reviewer-gate composition model, so it is decided and built THERE; this entry is
what a future session reads to know that the store-side half was considered,
scoped, and left unbuilt for a stated reason rather than missed.

---

## 15. The credential-leak control lives in BOTH the release driver and the push-time gates, and refuses shapes rather than addresses

**Statement.** Four vendor-prefixed credential shapes are refused before anything
is published from this repo: AWS access-key IDs, GitHub tokens (`ghp_`, `gho_`,
`ghu_`, `ghs_`, `ghr_` and the fine-grained `github_pat_` prefix), PEM
private-key headers, and `sk-` style API keys. Those four were chosen because
they catch the likeliest accidental paste into operator-facing text; a secret
carrying none of their prefixes is not covered, and this entry claims no more
than the four. They are declared ONCE, in `scripts/lib/secret-patterns.sh`,
together with the one function that looks for them.

Two consumers share that one declaration:

- `scripts/release.sh` checks both fetched artefacts — the Release body and the
  deployment contract — while they are still staged, before a byte is written,
  so a refusal leaves the working tree exactly as it was.
- `scripts/check-secret-leak.sh` checks the files a release bump writes (the app
  manifest, the compose file, and everything vendored under `upstream/`) at push
  time, as a `.local-ci.yml` step.

Every refusal names the CATEGORY and never the matched text.

Private-range and loopback IP literals are deliberately NOT refused.

**Why — both places, not one.** The driver is where upstream text ENTERS the
tree; the push is where it becomes PUBLIC. Those are different events, and a
control at only one of them leaves the other open. A driver-only check misses
every hand edit: DEPLOY.md § 3.1 documents the hand path as the supported
recovery for a machine without `docker` or an authenticated `gh`, and an edit
that changes the manifest's `releaseNotes` and the vendored copy TOGETHER
satisfies `check-release-notes-drift.sh` — that gate compares the two against
each other, not against the Release. A gate-only check would let the driver
fetch, write, and only then refuse, leaving the credential in the checkout and
breaking the tree-untouched-on-refusal property the staging design exists for.
So the control is in both places over one definition of the shapes
(`INVARIANTS.md` § Encapsulation), covering two different entry points rather
than restating one check twice.

**Why — the category and never the match.** Printing the matched text would
disclose the credential a second time, into the operator's terminal, their shell
history, and the CI log of every run that reproduced the failure. The category
name is enough to act on and discloses nothing.

**Why — shapes, not addresses.** A private-range or loopback IP check was
proposed and refused. This application's entire purpose is sweeping the
operator's own LAN, so its operator-facing text legitimately carries values like
`MINER_FLEET_SUBNETS=192.168.1.0/24` — the shipped `0.2.0` `releaseNotes` and
DEPLOY.md § 6 both do. A gate refusing private-range literals would have blocked
the last release and would block the next one that explains subnet
configuration. Those addresses are necessary prose in this repo, not a leak, and
entry 7 already keeps the operator's REAL subnet out of the tree by keeping the
setting on the box. `tests/test-check-secret-leak.sh` pins the non-refusal with a
case built on the shipped guidance, so the check cannot be "tightened" into
blocking correct releases without a red test.

**Revisit if.** A credential shape not in the four above is found in a published
artefact, upstream or here — the remedy is a new row in
`scripts/lib/secret-patterns.sh`, which extends both consumers at once, never a
second scanner. Or the operator-facing text stops being copied from a private
repo, which would remove the asymmetry this entry exists for; the gate would
still be worth its cost, so it would need a new reason rather than an automatic
removal.
