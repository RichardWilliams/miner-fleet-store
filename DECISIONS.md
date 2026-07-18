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
change, per codespace CLAUDE.md RULE #0.

---

## 1. Store id `pipfox`, app id `pipfox-miner-fleet`, app directory name equal to the app id

**Statement.** The store id is `pipfox`. The app id is `pipfox-miner-fleet`. The
app directory at the repo root is named `pipfox-miner-fleet` — byte-for-byte the
app id, with no suffix, no variation, and no separate display slug. The three
names are one decision, not three: changing any of them requires changing all
three in the same commit.

**Why.** umbrelOS imposes both halves of the constraint. An app id must be
prefixed with the id of the store that ships it, so the app cannot be called
`miner-fleet` while the store is called `pipfox` — umbreld will not resolve it.
And the app is located on disk by its id, so the directory name must equal the
app id exactly; a mismatch makes the app invisible to the store scan rather than
producing a diagnosable error. Because the store id feeds the app id and the app
id feeds the directory name, a partial rename leaves the store in a state that
looks correct in the diff and silently fails to install.

**Revisit if.** umbrelOS drops the store-id prefix requirement or the
id-equals-directory-name requirement, or the operator retires the `pipfox` store
identity in favour of a different one — in which case all three names move
together in a single change.

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
