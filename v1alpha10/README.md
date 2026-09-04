# StarRocks ACE Engine — artifact sources

This directory is the source of the StarRocks engine and blueprint we publish to a Cloudera
Anywhere Cloud (AWC) marketplace: `ecosystem.awc.cloudera.com/v1alpha10` objects, packaged as OCI
artifacts with plain `oras` and `helm`, verified end to end on a live AWC hub (see *Status*).

Two properties are deliberate:

- **No public images.** The three StarRocks images and the `kube-starrocks` chart are mirrored into
  a private registry we control and referenced from there; the engine wires an `imagePullSecret`
  into the operator, FE and BE pods. The engine therefore faces exactly what the enterprise engine
  will face: private chart + private images + a read-only credential handed to AWC.
- **Native Helm releases.** Charts are installed through `Engine.spec.releases[]`; there is no
  hand-written Flux object in the template, and no RBAC exists for that purpose.

## Files

| File | Role |
|---|---|
| `engine.yaml` | `Engine` (v1alpha10): `provides`, `configSchema` (incl. `imagePullSecret`), `imageCatalog` / `chartCatalog` references, `releases[]`, and a `template` holding only `AuthConfig` + `HTTPRoute` |
| `blueprint.yaml` | `Blueprint` (v1alpha10): `instances[{engine, minimumVersion}]`, `hardwareTiers[]`, `ui.displayName`, `outcome` |
| `supplementary.yaml` | multi-document: `Capability`, `ImageCatalog`, `ChartCatalog`, optional `ClusterRole`/`Binding`. **Must start with `---`.** The only committed file that names the registry prefix |
| `engine-config.json`, `blueprint-config.json` | the OCI config blobs (`schemaVersion`, `name`, `version`, display fields) |
| `bom.yaml` | **generated** by `gen-bom.sh`: every image/chart with its digest, resolved from the registry after mirroring — never hand-edited |
| `preflight.sh` | asserts every hub/Console rule we know (below) before anything is pushed; `push.sh` runs it first |
| `mirror.sh` | copies the images (`oras cp -r`, digests preserved) and the chart (`helm pull`/`push`) into the private registry |
| `gen-bom.sh` | writes `bom.yaml` from the catalogs + registry digests |
| `push.sh` | pushes `engines/<name>:<version>`, `blueprints/<name>:<version>`, and generates + pushes `catalog:latest` |
| `hub/manifestbundles.yaml` | `ManifestBundle` objects for the hub-side check (namespace `ace-hub-system`) |

## Hard rules, and where each one lives

| # | Rule | Enforced by |
|---|---|---|
| — | OCI repository is `<prefix>/engines/<engine metadata.name>` and `<prefix>/blueprints/<blueprint metadata.name>`; the tag is the version | **derived** in `push.sh` from `metadata.name` and the config blob — cannot be typed wrong |
| — | `catalog:latest` exists under the prefix with the right `registryPrefix` | **generated** in `push.sh` |
| R1 | `supplementary.yaml` starts with `---` (else ace-hub: `Object 'Kind' is missing`) | `preflight.sh` |
| R2 | every `ecosystem.awc.cloudera.com` object is `v1alpha10` | `preflight.sh` |
| R3 | engine / blueprint names are lowercase DNS labels (they become OCI paths and K8s names) | `preflight.sh` |
| R4 | config blobs carry the same `name` as the YAML `metadata.name` | `preflight.sh` |
| R5 | one version in `engine-config.json`, `blueprint-config.json`, `bom.yaml` | `preflight.sh` |
| R6 | `blueprint.instances[].engine` names this engine; `minimumVersion` ≤ published version | `preflight.sh` |
| R7 | `engine.spec.imageCatalog` / `chartCatalog` exist in `supplementary.yaml` | `preflight.sh` |
| R8 | every `releases[].chartID` and every `.Image.<id>` used in the engine exists in the catalogs | `preflight.sh` |
| R9 | `bom.yaml` images/charts equal the catalogs' (one source of truth) | `preflight.sh` |

Everything else the hub validates (field schema) it reports precisely in the `ManifestBundle`
`Validated` condition, so it is left to the hub check.

## Artifact layout (as published)

| artifact | repository | `artifactType` | layers |
|---|---|---|---|
| engine | `<prefix>/engines/starrocks-ace-engine:1.11.4` | `application/vnd.ace.engine.v1` | `engine.yaml`, `supplementary.yaml`, `bom.yaml` |
| blueprint | `<prefix>/blueprints/starrocks-ace-blueprint:1.11.4` | `application/vnd.ace.blueprint.v1` | `blueprint.yaml` |
| catalog | `<prefix>/catalog:latest` | `application/vnd.ace.catalog.v1` | `catalog.json` (generated) |

Versions are OCI **tags**: the Console lists the tags of each `engines/<name>` and
`blueprints/<name>` repository as the selectable versions (re-synced every 60 s); the catalog
carries no version. A new engine version is a new tag — re-run the four scripts with the new
version in the config blobs and catalogs (suffix the `ImageCatalog`/`ChartCatalog` names with it).

## Workflow

```
login → mirror → gen-bom → push (preflight runs first) → hub check → Console registration → deploy
```

```bash
P=ghcr.io/dxyan06/awc                              # any OCI registry you can write to

printf '%s' "$PAT" | oras login ghcr.io -u <user> --password-stdin        # write:packages
printf '%s' "$PAT" | helm registry login ghcr.io -u <user> --password-stdin

./mirror.sh  "$P"     # images + chart into the private registry
./gen-bom.sh "$P"     # resolve digests -> bom.yaml
./push.sh    "$P"     # preflight, then engine / blueprint / catalog:latest (+ timestamp tag)
```

Hub check: apply `hub/manifestbundles.yaml` in `ace-hub-system` and wait for
`Fetched / Validated / Ready = True`. ace-hub does not re-poll: after a re-push, delete and
recreate the bundles.

Console registration (control-plane side): append `<prefix>` to `MARKETPLACE_REGISTRIES` in
`awc-core/awc-taikun-secrets` and merge a **read-only** credential for the registry into
`awc-core/awc-console-registry-creds` (the reflector *source*; the copies in other namespaces are
overwritten), then restart `awc-console`. The blueprint appears in the Marketplace within a minute.

## Changing the registry prefix

The prefix appears in exactly one committed file, `supplementary.yaml` (the `registry:` and
`repository:` fields of the two catalogs); everything else takes it as an argument:

```bash
sed -i 's#ghcr.io#<registry>#; s#dxyan06/awc/#<namespace>/#' supplementary.yaml
```

then rerun `mirror.sh`, `gen-bom.sh`, `push.sh` with the new prefix. `preflight.sh` (R9) catches a
stale `bom.yaml`.

## Status (2026-09-03)

- Hub: both bundles `Fetched / Validated / Ready`; inventory lists the engine, the
  `starrocks-cluster` capability and both catalogs.
- Console: the `PHOENIXAI / StarRocks` card is in the Marketplace.
- **Deployed twice from the card** (`cldrphnx-starrocks-cluster-01`, `-02`): workload cluster
  provisioned, `EngineDeployment` `Running`, FE LEADER + BE `Alive` (3.4.3) pulled from the private
  registry with the default `imagePullSecret` name `awc-console-registry-creds`, landing page
  served through the cluster's `HTTPRoute`. The `imagePullSecret` default therefore holds.

## Not yet verified

- whether ace-hub requires the `bom.yaml` layer at all (accepted; dropping it untested);
- whether ace-operator needs the `ClusterRole` in `supplementary.yaml` for the `HTTPRoute` /
  `AuthConfig` it renders (the objects were created; Cloudera's `valkey-engine` ships no RBAC);
- the `HelmRelease` names ace-operator gives `releases[]` on the workload cluster (needs the
  workload kubeconfig, stored on the hub as `ace-hub-system/<cluster>-kubeconfig`).
