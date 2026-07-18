# miner-fleet-store

Umbrel Community App Store for [miner-fleet](https://github.com/RichardWilliams/miner-fleet),
a self-hosted fleet manager for Bitaxe and NerdQAxe++ Bitcoin ASIC miners.

This repository is the deploy mechanism. umbrelOS clones it over plain git with
no credentials and re-polls it on a short interval, so it must stay **public**.
Publishing a new release of the app means bumping the version and image digest
here — not touching the Umbrel box.

## Adding this store to umbrelOS

One-time, per box:

1. In the Umbrel UI, open the App Store → **⋯** → **Community App Stores**.
2. Add `https://github.com/RichardWilliams/miner-fleet-store`.
3. Install **Miner Fleet** from the **Pipfox** store that appears.

The app is served on host port **3007**.

Update behaviour, the release procedure, and recovery steps are in
[`DEPLOY.md`](DEPLOY.md).

## Layout

```
umbrel-app-store.yml          store id and display name
pipfox-miner-fleet/
  umbrel-app.yml              app manifest: version, port, description
  docker-compose.yml          app_proxy + server, image pinned by tag + digest
```

Umbrel requires the app id to be prefixed with the store id, and the app
directory name to equal the app id exactly. Those two constraints plus the
image-pinning rule are recorded in [`DECISIONS.md`](DECISIONS.md).

## A note on visibility

This repo is public and the container image is public; the application's source
repository is private. That split is deliberate — umbreld pulls images with no
registry authentication, so a private image cannot be deployed this way.

Nothing identifying a machine, network, or location may be committed here.
