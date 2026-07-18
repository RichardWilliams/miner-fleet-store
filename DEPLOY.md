# DEPLOY — operator runbook

How this store is added to umbrelOS, how updates reach the box, how a release is
cut, and what to do when one goes wrong.

**Do not paste machine-specific values into this file.** This repository is
public. Host addresses, hostnames, MAC addresses and port-scan output belong in
your terminal, never in a commit, a manifest comment, or a PR description.

---

## 1. One-time setup

Done once per Umbrel box. After this, releases reach the box without touching it.

**Mandatory operator checklist — the deploy is not live until all four pass.**

- [ ] In the Umbrel UI, open the App Store, then the **⋯** menu → **Community App Stores**.
- [ ] Add this repository's URL: `https://github.com/RichardWilliams/miner-fleet-store`. It should be accepted without a credential prompt — the repo is public and umbreld clones it anonymously. A credential prompt means the repo visibility has regressed; stop and fix that first.
- [ ] Install **Miner Fleet** from the Pipfox store that now appears.
- [ ] Open the app and confirm its UI loads. It is served through `app_proxy` on host port **3007** — the port declared in `umbrel-app.yml`, not the container's internal 3000.

If the app installs but the UI does not load, go to § 4 Recovery.

### Prerequisite: the image must be public

umbreld pulls with no registry authentication, so a private package fails with
401. The image's source repository is private while the image itself is public —
that split is deliberate and is recorded in miner-fleet's DECISIONS.md entry 1.
A ghcr package inherits its source repo's visibility on first publish, so it is
created private and must be flipped once, manually, in the GitHub UI. miner-fleet's
README documents that step.

---

## 2. How updates actually work

umbreld re-clones every community app store on a **5-minute interval**
(`updateInterval = '5m'` in umbreld's `app-store.ts`). It compares the `version`
field in `umbrel-app.yml` against the installed version, and surfaces an **Update**
button in the Umbrel UI when they differ.

Updates are **auto-detected, manually applied**. Umbrel does not upgrade the app
behind your back — bumping `version` here makes the button appear; you decide when
to press it.

**Expect up to 5 minutes of lag.** There is no on-demand refresh button;
`getumbrel/umbrel#2083` is the open upstream request for one. If you need the box
to notice a change immediately, the community workaround is to remove the store
URL and re-add it, which forces a fresh clone.

A bumped `version` with an unchanged image digest is a no-op deployment: umbrelOS
shows an update, pulls the same bytes, and nothing changes. Both fields move
together — see § 3.

---

## 3. Release procedure

A release starts in **miner-fleet**, not here. Follow that repo's README release
section first; it ends with a mandatory artefact verification that gates this
store bump. Do not begin here.

Once miner-fleet has published `X.Y.Z` and you have verified the published
artefact resolves and is `linux/amd64`-only:

1. **Capture the index digest.** Read the `Digest:` line from:

   ```bash
   docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z
   ```

   That top-level value is the **multi-arch index digest**. Use it. Do NOT use a
   digest from the indented `Manifests:` list below it — those are per-platform
   manifests, and umbreld resolves the index.

2. **Edit exactly two fields, in two files.** Each value lives in exactly one
   greppable place, so a release bump is a two-field edit rather than a
   search-and-replace:

   | File | Field |
   |---|---|
   | `pipfox-miner-fleet/umbrel-app.yml` | `version: "X.Y.Z"` |
   | `pipfox-miner-fleet/docker-compose.yml` | the `image:` tag **and** `@sha256:` digest |

3. **Refresh `releaseNotes`** in `umbrel-app.yml`. This is operator-facing text
   shown in the Umbrel UI — write what changed, in plain language.

4. **Open a PR and merge it.** The merge to `main` is what publishes the release;
   umbreld polls `main`.

5. **Wait up to 5 minutes**, then confirm the Update button appears in the Umbrel
   UI and apply it.

---

## 4. Recovery

**The app will not start after an update.** Check the app's logs in the Umbrel UI
first. The most common cause is an image reference that does not resolve — a
mistyped digest, or a digest that names a per-platform manifest instead of the
index. Verify the exact reference from the compose file:

```bash
docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z@sha256:<digest>
```

If that fails, the reference is wrong. Correct it here and merge; the box picks
up the fix on the next poll.

**The pull fails with 401.** The published package has gone private. Flip it back
to public in the GitHub package settings; no store change is needed.

**The pull fails with a manifest/platform error.** The release published something
other than `linux/amd64`, or the amd64 entry is missing. This is a miner-fleet
release defect — fix it there and cut a new patch release. Do not work around it
here.

**Roll back.** Set `version` and the image reference back to the previous
release's values and merge. Umbrel treats it as an update like any other. Keeping
the previous release's tag and digest in the PR description of each release bump
makes this a copy-paste rather than an archaeology exercise.

**The store URL will not add, or the app never appears.** Confirm the repo is
public and that `umbrel-app-store.yml` is at the repo root. Then confirm the app
directory name is byte-for-byte equal to the app id — a mismatch makes the app
invisible to the store scan rather than producing a diagnosable error.

**The container is running but the browser shows a gateway/proxy error.** The
app itself is fine; `app_proxy` cannot reach it. `app_proxy` resolves the
application container by the compose-generated name in its `APP_HOST` — currently
`pipfox-miner-fleet_server_1` — so renaming the `server` service, or changing the
app id without changing `APP_HOST` to match, breaks the proxy while leaving the
container up and healthy. Nothing reports this as a misconfiguration: the app
looks installed and running, and only the browser sees the failure. Check that
the compose service is still named `server` and that `APP_HOST` still reads
`<app-id>_server_1`.

**The Umbrel UI shows the app as unhealthy.** The `healthcheck` polls
`/api/health` inside the container. Note this does not by itself restart
anything — Docker's `restart:` policy does not act on health status — so an
unhealthy-but-running app stays up and must be restarted from the Umbrel UI.
Check the app's logs for why the endpoint stopped answering.

---

## 5. Decisions and why they are not free to change

Full statements with revisit conditions are in [`DECISIONS.md`](DECISIONS.md).
Summarised here so nobody "simplifies" one without meeting its rationale.

**Bridge networking, not `network_mode: host`** (entry 2). A bridge container
already reaches LAN addresses outbound, which is what sweeping the miners' HTTP
API needs. Host networking adds only broadcast/mDNS reception — and costs the
`app_proxy` auth layer in front of the app. Do not switch to host networking to
"fix" a discovery problem without first designing an authentication path that
does not depend on `app_proxy`.

**Pinned by semver tag AND digest together** (entry 3). The digest makes the
deployment reproducible; the tag makes it legible to a human deciding whether to
accept an update. `latest`, a bare commit SHA, and a bare digest are each banned —
the first is neither reproducible nor informative, the second carries no ordering,
the third is unreadable.

**The service must be named `server`** (entry 1). `app_proxy` resolves
`APP_HOST: pipfox-miner-fleet_server_1`; the `_server_1` suffix is a hard naming
contract. Renaming the service silently breaks the proxy.

**No volumes.** The application is stateless at this version — no database, and
nothing it writes needs to survive a restart. Declaring storage the app never
touches would be configuration added in case it is needed later. When the app
gains persistent state, the mounts land with the code that uses them. Record for
that change: the container runs as **uid 1001** (`minerfleet`, gid 1001
`nodejs`), so any host directory bind-mounted into it must be writable by 1001 —
not 1000. That change is also the point at which to verify against umbreld's
source whether `APP_DATA_DIR` is re-seeded on *update* or only on *install*; that
question is currently unanswered and should not be assumed either way.
