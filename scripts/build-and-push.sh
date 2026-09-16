#!/usr/bin/bash
# Build and push all three images. Run from the repository root.
#
#   NS=quay.io/tichomir VER=1.0 ./scripts/build-and-push.sh
#
# Which Lightwell track a build resolves against is decided by
# images/app/pip.conf, not by this script. That is deliberate: it should be a
# visible, deliberate edit rather than a flag you forget you passed.
set -euo pipefail

NS="${NS:?Set NS, e.g. NS=quay.io/tichomir}"
VER="${VER:-1.0}"
BASE_TAG="${BASE_TAG:-10.1}"
BUILD_DB="${BUILD_DB:-yes}"
# PUSH=no builds without touching the registry. Useful before registry
# permissions are sorted, and for the first provisioning pass: the qcow2 build
# reads from local podman storage with --local, so the hosts only need the
# registry once they start doing `bootc upgrade`.
PUSH="${PUSH:-yes}"

cd "$(dirname "$0")/.."

for f in images/app/pip.conf images/app/netrc; do
    if [[ ! -f "${f}" ]]; then
        echo "Missing ${f}. Copy ${f}.example and edit it." >&2
        exit 1
    fi
done

# Report which dependency state this build will produce, and label the image
# with it, so `skopeo inspect` can answer the question without booting the host.
DEP_LINE="$(grep -E '^jinja2==' requirements.txt || true)"
if [[ "${DEP_LINE}" == *rhlw* ]]; then
    DEP_STATE="remediated"
else
    DEP_STATE="vulnerable"
fi
# CROSS-CHECK THE LABEL AGAINST WHERE pip WILL ACTUALLY RESOLVE.
#
# DEP_STATE above is derived from requirements.txt alone. That is not enough:
# PEP 440 lets a plain "==2.11.3" specifier match "2.11.3+rhlw00001", and the
# Lightwell index has nothing else. So pip.conf pointing at a Lightwell index
# while the pin carries no rhlw silently installs the REMEDIATED wheel and
# labels the image `vulnerable`.
#
# That mislabelled image is indistinguishable from the real thing until it is
# on screen, so refuse to build it.
if [[ "${DEP_STATE}" == "vulnerable" ]] \
   && grep -qE '^[[:space:]]*index-url.*(lightwell|packages\.redhat\.com)' images/app/pip.conf; then
    cat >&2 <<'MISMATCH'
REFUSING TO BUILD: the pin and the index disagree.

  requirements.txt pins a version with no `rhlw` suffix, so this build is
  labelled `vulnerable` - but images/app/pip.conf points at a Lightwell index.

  A plain `==2.11.3` specifier MATCHES `2.11.3+rhlw00001` under PEP 440, and
  the Lightwell index serves nothing else. pip would install the remediated
  wheel into an image labelled vulnerable, and you would not find out until
  the CVE observable failed to fire on camera.

  For a vulnerable build:   ./scripts/switch-track.sh vulnerable
  For a remediated build:   pin jinja2==2.11.3+rhlw00001 in requirements.txt

MISMATCH
    exit 1
fi

echo "== dependency state: ${DEP_STATE} (${DEP_LINE}) =="

echo "== baseos:${BASE_TAG} (FROM rhel-bootc:${BASE_TAG}) =="
podman build --build-arg "BASE_TAG=${BASE_TAG}" \
    -t "${NS}/baseos:${BASE_TAG}" images/baseos

echo "== im-train:${VER} =="
# pip.conf and netrc go in as build SECRETS, not COPY. A copied file lives in
# its own layer forever and a later rm only hides it - and these images are
# pushed to public repositories. See the comment in images/app/Containerfile.
podman build \
    --build-arg "NS=${NS}" \
    --build-arg "BASE_TAG=${BASE_TAG}" \
    --build-arg "APP_VERSION=${VER}" \
    --build-arg "DEP_STATE=${DEP_STATE}" \
    --secret "id=pipconf,src=images/app/pip.conf" \
    --secret "id=netrc,src=images/app/netrc" \
    -t "${NS}/im-train:${VER}" \
    -f images/app/Containerfile .

if [[ "${BUILD_DB}" == "yes" ]]; then
    echo "== im-train-db:pg16 =="
    podman build --build-arg "NS=${NS}" --build-arg "BASE_TAG=${BASE_TAG}" \
        -t "${NS}/im-train-db:pg16" -f images/db/Containerfile .
fi

if [[ "${PUSH}" != "yes" ]]; then
    cat <<NEXT

Built locally; PUSH=no, so the registry was not touched.

  $(podman images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E "${NS##*/}|im-train|baseos" | sed 's/^/  /')

Provision from local storage with bootc-image-builder --local, or rerun with
PUSH=yes once the registry accepts the push.
NEXT
    exit 0
fi

echo "== push =="
podman push "${NS}/baseos:${BASE_TAG}"
podman push "${NS}/im-train:${VER}"
[[ "${BUILD_DB}" == "yes" ]] && podman push "${NS}/im-train-db:pg16"

cat <<NEXT

Built and pushed. The hosts track :prod, so nothing has changed for them yet.

Promote when ready:
  NS=${NS} VER=${VER} ./scripts/promote.sh

Note: im-train-db is built once and never rebuilt. Pass BUILD_DB=no on
subsequent runs to save a couple of minutes per take.
NEXT
