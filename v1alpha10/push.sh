#!/usr/bin/env bash
# Publish the engine, the blueprint and the catalog index as OCI artifacts, laid out exactly the
# way Cloudera's own marketplace artifacts are (media types, config blobs, annotations observed on
# container.repository.cloudera.com/cloudera/awc/marketplace, 2026-09-02). Replaces publish.sh's
# dependency on the internal `awc-marketplace` CLI.
#
#   ./push.sh ghcr.io/dxyan06/awc        # after mirror.sh and gen-bom.sh
#
# Repository layout is a hard rule enforced by ace-hub's ManifestBundle controller:
#   <prefix>/engines/<engine metadata.name>       <prefix>/blueprints/<blueprint metadata.name>
# plus <prefix>/catalog:latest, which is what the AWC Console reads to build the Marketplace.
# Both paths and the tag are DERIVED here from metadata.name and the config blob's version, so they
# cannot be typed wrong; the remaining rules (leading `---`, v1alpha10, name/version consistency,
# catalog references, BOM == catalogs) are asserted by preflight.sh.
set -euo pipefail

P="${1:?usage: $0 <registry-prefix>   e.g. ghcr.io/dxyan06/awc}"
VENDOR="${VENDOR:-PhoenixAI}"
cd "$(dirname "$0")"

# Every hub/Console rule we know of is checked before the first byte is pushed (see preflight.sh).
./preflight.sh

ENGINE=$(yq -r '.metadata.name' engine.yaml)
BLUEPRINT=$(yq -r '.metadata.name' blueprint.yaml)
VERSION=$(jq -r .version engine-config.json)

echo "==> engine   $P/engines/$ENGINE:$VERSION"
oras push "$P/engines/$ENGINE:$VERSION" \
  --artifact-type application/vnd.ace.engine.v1 \
  --config engine-config.json:application/vnd.ace.engine.config.v1+json \
  --annotation "com.cloudera.ace.engine.name=$ENGINE" \
  --annotation "com.cloudera.ace.engine.version=$VERSION" \
  --annotation "org.opencontainers.image.vendor=$VENDOR" \
  engine.yaml:application/vnd.ace.engine.definition.v1+yaml \
  supplementary.yaml:application/vnd.ace.supplementary.v1+yaml \
  bom.yaml:application/vnd.ace.bom.v1+yaml

echo "==> blueprint $P/blueprints/$BLUEPRINT:$VERSION"
oras push "$P/blueprints/$BLUEPRINT:$VERSION" \
  --artifact-type application/vnd.ace.blueprint.v1 \
  --config blueprint-config.json:application/vnd.ace.blueprint.config.v1+json \
  --annotation "com.cloudera.ace.blueprint.name=$BLUEPRINT" \
  --annotation "com.cloudera.ace.blueprint.version=$VERSION" \
  --annotation "org.opencontainers.image.vendor=$VENDOR" \
  blueprint.yaml:application/vnd.ace.blueprint.definition.v1+yaml

# The catalog is generated here so registryPrefix can never drift from where things were pushed.
echo "==> catalog  $P/catalog:latest"
tmp=$(mktemp -d)
jq -n --arg p "$P" \
  --arg en "$ENGINE"    --arg ed "$(jq -r .displayName engine-config.json)"    --arg ee "$(jq -r .description engine-config.json)" \
  --arg bn "$BLUEPRINT" --arg bd "$(yq -r '.spec.ui.displayName' blueprint.yaml)" --arg be "$(jq -r .description blueprint-config.json)" \
  '{schemaVersion:"1.0.0", registryPrefix:$p,
    engines:   [{name:$en, displayName:$ed, description:$ee}],
    blueprints:[{name:$bn, displayName:$bd, description:$be}]}' > "$tmp/catalog.json"
jq -n --arg p "$P" '{schemaVersion:"1.0.0", registryPrefix:$p, engineCount:1, blueprintCount:1}' > "$tmp/catalog-config.json"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
( cd "$tmp" && oras push "$P/catalog:latest,$stamp" \
    --artifact-type application/vnd.ace.catalog.v1 \
    --config catalog-config.json:application/vnd.ace.catalog.config.v1+json \
    --annotation "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --annotation "org.opencontainers.image.vendor=$VENDOR" \
    catalog.json:application/vnd.ace.catalog.v1+json )
rm -rf "$tmp"

# ghcr.io implements repository listing poorly (oras repo ls can hang), so verify by name instead.
echo "==> published:"
for r in "engines/$ENGINE" "blueprints/$BLUEPRINT" catalog; do
  printf '    %-45s tags: %s\n' "$P/$r" "$(oras repo tags "$P/$r" | tr '\n' ' ')"
done
