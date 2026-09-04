#!/usr/bin/env bash
# Generate bom.yaml — the bill of materials the `awc-marketplace` CLI would have produced — by
# resolving every image and chart in supplementary.yaml to its digest in OUR registry.
#
#   ./gen-bom.sh ghcr.io/dxyan06/awc      # after mirror.sh
#
# Shape copied from Cloudera's engines/valkey-engine:5.4.9 and engines/cai-plugin:1.6.0 bom.yaml:
#   schemaVersion 1.0.0 / engine{name,version} / dependencies / instances /
#   images[{registry,repository,tag,digest,mediaType}] / operators / charts[{id,...,version,digest}]
# Whether ace-hub requires this layer is not yet known; it is produced so the artifact matches
# Cloudera's exactly, and dropping it is a one-line experiment later.
set -euo pipefail

P="${1:?usage: $0 <registry-prefix>   e.g. ghcr.io/dxyan06/awc}"
cd "$(dirname "$0")"

ENGINE_NAME=starrocks-ace-engine
ENGINE_VERSION=1.11.4
CHART_VERSION=1.11.4

desc() { oras manifest fetch --descriptor "$1"; }

# image <ref>  -> one images[] entry
image() {
  local ref=$1 d reg rest repo tag
  d=$(desc "$ref")
  reg=${ref%%/*}; rest=${ref#*/}; repo=${rest%%:*}; tag=${rest##*:}
  cat <<EOF
    - registry: ${reg}
      repository: ${repo}
      tag: ${tag}
      digest: $(jq -r .digest <<<"$d")
      mediaType: $(jq -r .mediaType <<<"$d")
EOF
}

chart_digest=$(desc "$P/charts/kube-starrocks:${CHART_VERSION}" | jq -r .digest)

cat > bom.yaml <<EOF
schemaVersion: 1.0.0
engine:
    name: ${ENGINE_NAME}
    version: ${ENGINE_VERSION}
dependencies: []
instances: []
images:
$(image "$P/images/starrocks/operator:v1.11.4")
$(image "$P/images/starrocks/fe-ubuntu:3.4.3")
$(image "$P/images/starrocks/be-ubuntu:3.4.3")
operators: []
charts:
    - id: kubeStarrocks
      registry: ${P%%/*}
      repository: ${P#*/}/charts/kube-starrocks
      version: ${CHART_VERSION}
      digest: ${chart_digest}
EOF

echo "==> wrote bom.yaml"
cat bom.yaml
