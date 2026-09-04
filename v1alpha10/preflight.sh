#!/usr/bin/env bash
# Preflight: check every rule the AWC hub / Console enforce on our artifacts BEFORE anything is
# pushed. Each rule below was learnt from the ManifestBundle CRD docs or from a real failure; the
# hub reports most violations as an opaque `Fetched=False`, so we check them here where the message
# can say what is wrong.
#
#   ./preflight.sh            # run from anywhere; push.sh calls it first
#
# Rules (R1..R9):
#   R1  supplementary.yaml starts with `---` (ace-hub decodes each `---` segment; a leading comment
#       fails with "Object 'Kind' is missing").
#   R2  every ecosystem.awc.cloudera.com object is apiVersion v1alpha10 (v1alpha9 renders no wizard).
#   R3  metadata.name of engine/blueprint is a valid lowercase DNS label — it becomes the OCI
#       repository path engines/<name> and blueprints/<name>, which ace-hub requires verbatim.
#   R4  the OCI config blobs carry the same name as the YAML metadata.name (Console reads the blob).
#   R5  one version everywhere: engine-config.json, blueprint-config.json, bom.yaml engine.version.
#       (The OCI tag is derived from this value by push.sh, so it cannot drift.)
#   R6  blueprint.instances[].engine == engine metadata.name, and minimumVersion <= that version.
#   R7  engine.spec.imageCatalog / chartCatalog name an ImageCatalog / ChartCatalog that exists in
#       supplementary.yaml.
#   R8  every releases[].chartID exists in the ChartCatalog; every `.Image.<id>` used in engine.yaml
#       exists in the ImageCatalog.
#   R9  bom.yaml lists exactly the ImageCatalog images (registry/repository/tag) and ChartCatalog
#       charts (repository/version) — the BOM and the catalogs must be one source of truth.
set -euo pipefail
cd "$(dirname "$0")"

fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
need() { command -v "$1" >/dev/null || { echo "missing tool: $1"; exit 2; }; }
need yq; need jq

ENGINE=$(yq -r '.metadata.name' engine.yaml)
BLUEPRINT=$(yq -r '.metadata.name' blueprint.yaml)
VERSION=$(jq -r .version engine-config.json)
echo "preflight: engine=$ENGINE blueprint=$BLUEPRINT version=$VERSION"

# R1
first=$(grep -v '^[[:space:]]*$' supplementary.yaml | head -1)
[ "$first" = "---" ] && ok "R1 supplementary.yaml starts with ---" || bad "R1 supplementary.yaml must start with --- (first line is: $first)"

# R2
bad_api=$( { yq -r '.apiVersion' engine.yaml blueprint.yaml; yq -r 'select(.apiVersion != null) | .apiVersion' supplementary.yaml; } \
  | grep 'ecosystem.awc.cloudera.com' | grep -v '/v1alpha10$' || true)
[ -z "$bad_api" ] && ok "R2 all ecosystem.awc.cloudera.com objects are v1alpha10" || bad "R2 non-v1alpha10 apiVersion found: $bad_api"

# R3
dns='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
for n in "$ENGINE" "$BLUEPRINT"; do
  [[ "$n" =~ $dns ]] && ok "R3 '$n' is a valid repository/DNS name" || bad "R3 '$n' is not a lowercase DNS label; it becomes the OCI path"
done

# R4
[ "$(jq -r .name engine-config.json)" = "$ENGINE" ]       && ok "R4 engine-config.json name matches"    || bad "R4 engine-config.json .name != $ENGINE"
[ "$(jq -r .name blueprint-config.json)" = "$BLUEPRINT" ] && ok "R4 blueprint-config.json name matches" || bad "R4 blueprint-config.json .name != $BLUEPRINT"

# R5
bv=$(jq -r .version blueprint-config.json)
[ "$bv" = "$VERSION" ] && ok "R5 blueprint-config.json version = $VERSION" || bad "R5 blueprint-config.json version $bv != $VERSION"
if [ -f bom.yaml ]; then
  bn=$(yq -r '.engine.name' bom.yaml); bver=$(yq -r '.engine.version' bom.yaml)
  [ "$bn" = "$ENGINE" ] && [ "$bver" = "$VERSION" ] && ok "R5 bom.yaml engine $bn/$bver matches" || bad "R5 bom.yaml engine is $bn/$bver, expected $ENGINE/$VERSION (re-run gen-bom.sh)"
else
  bad "R5 bom.yaml missing — run ./gen-bom.sh <prefix>"
fi

# R6
while IFS=$'\t' read -r ie imin; do
  [ "$ie" = "$ENGINE" ] && ok "R6 blueprint instance engine '$ie' matches" || bad "R6 blueprint instance references engine '$ie', not '$ENGINE'"
  lowest=$(printf '%s\n%s\n' "$imin" "$VERSION" | sort -V | head -1)
  [ "$lowest" = "$imin" ] && ok "R6 minimumVersion $imin <= $VERSION" || bad "R6 minimumVersion $imin is above the published version $VERSION — nothing would be selectable"
done < <(yq -r '.spec.instances[] | [.engine, .minimumVersion] | @tsv' blueprint.yaml)

# R7
ic=$(yq -r '.spec.imageCatalog' engine.yaml); cc=$(yq -r '.spec.chartCatalog' engine.yaml)
yq -r 'select(.kind == "ImageCatalog") | .metadata.name' supplementary.yaml | grep -qx "$ic" \
  && ok "R7 ImageCatalog '$ic' present in supplementary.yaml" || bad "R7 engine.spec.imageCatalog '$ic' has no ImageCatalog in supplementary.yaml"
yq -r 'select(.kind == "ChartCatalog") | .metadata.name' supplementary.yaml | grep -qx "$cc" \
  && ok "R7 ChartCatalog '$cc' present in supplementary.yaml" || bad "R7 engine.spec.chartCatalog '$cc' has no ChartCatalog in supplementary.yaml"

# R8
chart_ids=$(yq -r 'select(.kind == "ChartCatalog") | .spec.charts[].id' supplementary.yaml)
for id in $(yq -r '.spec.releases[].chartID' engine.yaml); do
  grep -qx "$id" <<<"$chart_ids" && ok "R8 releases[].chartID '$id' exists in ChartCatalog" || bad "R8 releases[].chartID '$id' not in ChartCatalog ids: $(tr '\n' ' ' <<<"$chart_ids")"
done
image_ids=$(yq -r 'select(.kind == "ImageCatalog") | .spec.images[].id' supplementary.yaml)
for id in $(grep -o '\.Image\.[A-Za-z0-9_]*' engine.yaml | sed 's/\.Image\.//' | sort -u); do
  grep -qx "$id" <<<"$image_ids" && ok "R8 template uses .Image.$id (in ImageCatalog)" || bad "R8 template uses .Image.$id but ImageCatalog has: $(tr '\n' ' ' <<<"$image_ids")"
done

# R9
if [ -f bom.yaml ]; then
  want_img=$(yq -r 'select(.kind == "ImageCatalog") | .spec.images[] | .registry + "/" + .repository + ":" + .tag' supplementary.yaml | sort)
  have_img=$(yq -r '.images[] | .registry + "/" + .repository + ":" + .tag' bom.yaml | sort)
  [ "$want_img" = "$have_img" ] && ok "R9 bom.yaml images == ImageCatalog images" || bad "R9 bom.yaml images differ from ImageCatalog (re-run gen-bom.sh or fix supplementary.yaml)"
  want_ch=$(yq -r 'select(.kind == "ChartCatalog") | .spec.charts[] | .registry + "/" + .repository + ":" + .version' supplementary.yaml | sort)
  have_ch=$(yq -r '.charts[] | .registry + "/" + .repository + ":" + .version' bom.yaml | sort)
  [ "$want_ch" = "$have_ch" ] && ok "R9 bom.yaml charts == ChartCatalog charts" || bad "R9 bom.yaml charts differ from ChartCatalog"
fi

[ $fail -eq 0 ] && echo "preflight: all rules pass" || { echo "preflight: FAILED — fix the lines marked FAIL before pushing"; exit 1; }
