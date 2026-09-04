#!/usr/bin/env bash
# Copy the three StarRocks images and the kube-starrocks chart into OUR private registry, so that
# nothing is pulled from Docker Hub or the public Helm repo at deploy time.
#
#   ./mirror.sh ghcr.io/dxyan06/awc
#
# Prerequisites: `oras login <registry>` and `helm registry login <registry>` already done for the
# destination; `oras` (>= 1.2), `helm` (v3), network access to docker.io and starrocks.github.io.
#
# `oras cp` copies manifests byte-for-byte, so the digests recorded later by gen-bom.sh are the
# same digests the images carry upstream. `-r` walks a multi-arch index and brings every platform.
set -euo pipefail

P="${1:?usage: $0 <registry-prefix>   e.g. ghcr.io/dxyan06/awc}"

CHART_VERSION=1.11.4
OPERATOR_TAG=v1.11.4
SR_TAG=3.4.3

echo "==> images: docker.io/starrocks/* -> $P/images/starrocks/*"
oras cp -r "docker.io/starrocks/operator:${OPERATOR_TAG}"  "$P/images/starrocks/operator:${OPERATOR_TAG}"
oras cp -r "docker.io/starrocks/fe-ubuntu:${SR_TAG}"        "$P/images/starrocks/fe-ubuntu:${SR_TAG}"
oras cp -r "docker.io/starrocks/be-ubuntu:${SR_TAG}"        "$P/images/starrocks/be-ubuntu:${SR_TAG}"

echo "==> chart: starrocks/kube-starrocks ${CHART_VERSION} -> oci://$P/charts/kube-starrocks"
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator >/dev/null 2>&1 || true
helm repo update >/dev/null
tmp=$(mktemp -d)
helm pull starrocks/kube-starrocks --version "${CHART_VERSION}" -d "$tmp"
helm push "$tmp/kube-starrocks-${CHART_VERSION}.tgz" "oci://$P/charts"
rm -rf "$tmp"

# ghcr.io does not implement the repository catalog API, so `oras repo ls` hangs there; list tags per repo instead.
echo "==> done. Verify:"
for r in images/starrocks/operator images/starrocks/fe-ubuntu images/starrocks/be-ubuntu charts/kube-starrocks; do
  printf '    %-45s tags: %s\n' "$P/$r" "$(oras repo tags "$P/$r" | tr '\n' ' ')"
done
