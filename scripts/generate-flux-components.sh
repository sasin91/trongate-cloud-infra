#!/usr/bin/env bash
# Generate the committed Flux component manifest.
#
# A fork does not run this. The maintainer runs it once per Flux upgrade and
# commits the result, so that an upgrade arrives as a reviewable diff rather
# than as a side effect of whichever CLI version somebody happened to have.
#
# Usage:
#     ./scripts/generate-flux-components.sh                 # pinned version
#     FLUX_VERSION=v2.9.4 ./scripts/generate-flux-components.sh
#
set -euo pipefail

# The pinned Flux version. This is the single place the version is declared;
# it is also the version continuous integration compares against upstream.
#
# v2.9.3 was the current release on 2026-08-03. Its controllers:
#     source-controller        v1.9.3
#     kustomize-controller     v1.9.4
#     helm-controller          v1.6.3
#     notification-controller  v1.9.2
FLUX_VERSION="${FLUX_VERSION:-v2.9.3}"

# The four default controllers, named explicitly rather than left to the
# CLI's default, because a default is a value somebody else can change.
# TRONGATE-CLOUD: plus image-reflector-controller and
# image-automation-controller, which roll out trongate.cloud's platform images
# on every push to its main (apps/trongate-cloud/image-automation). The kit
# itself does not do image automation.
# Deliberately excluded: source-watcher (a sample controller, not a platform
# component).
FLUX_COMPONENTS="source-controller,kustomize-controller,helm-controller,notification-controller,image-reflector-controller,image-automation-controller"

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/clusters/production/flux-system"
OUT_FILE="${OUT_DIR}/gotk-components.yaml"

if ! command -v flux >/dev/null 2>&1; then
  cat >&2 <<EOF
error: the 'flux' command-line tool is not on PATH.

Install it from https://github.com/fluxcd/flux2/releases/tag/${FLUX_VERSION}
and run this script again. Do not hand-write ${OUT_FILE##*/}, and do not
substitute the 'install.yaml' asset attached to the release: that asset is the
all-components superset and would install three controllers this kit does not
run.
EOF
  exit 1
fi

# The CLI version and the manifest version are two different things. --version
# below pins the manifests; this check pins the tool that renders them, so the
# output does not quietly depend on which CLI was installed.
cli_version="$(flux version --client --short 2>/dev/null | awk '{print $NF}')"
if [ "${cli_version}" != "${FLUX_VERSION}" ]; then
  echo "warning: flux CLI is ${cli_version}, generating manifests for ${FLUX_VERSION}" >&2
fi

echo "Generating ${OUT_FILE}"
echo "  version:    ${FLUX_VERSION}"
echo "  components: ${FLUX_COMPONENTS}"

# THE EXACT COMMAND. Everything above is argument assembly.
flux install \
  --export \
  --version="${FLUX_VERSION}" \
  --components="${FLUX_COMPONENTS}" \
  --namespace=flux-system \
  > "${OUT_FILE}"

# An empty or truncated write is the failure this catches. `flux install`
# exiting zero having produced nothing would leave a file that builds to no
# resources, applies cleanly, and installs no Flux.
if ! grep -q "kind: Deployment" "${OUT_FILE}"; then
  echo "error: generated manifest contains no Deployment — refusing to keep it" >&2
  exit 1
fi

echo
echo "Wrote $(wc -l < "${OUT_FILE}") lines."
echo "Review the diff before committing. The controller image tags in it are"
echo "the version this cluster will run."
