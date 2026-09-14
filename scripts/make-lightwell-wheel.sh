#!/usr/bin/bash
# Track B: build a Lightwell-shaped remediated wheel.
#
# Produces a genuine backport - the upstream fix cherry-picked onto the pinned
# version - labelled with the Lightwell local-version suffix. The result is a
# real fix in a real artifact; only the provenance is local.
#
# Keep the resulting diff open in an editor. Fifteen seconds of it on screen in
# Act 3 is worth a paragraph of narration: the patch scope is the fix and
# nothing else, which IS the Lightwell model.
#
# Version form: Java uses ".rhlw-0000X". Python cannot - it is not valid PEP 440
# - so a local version is used instead: "2.11.3+rhlw.00001". Confirm the exact
# string the real index uses before recording, and match it here so the two
# tracks are visually interchangeable.
set -euo pipefail

REPO="${REPO:-https://github.com/pallets/jinja.git}"
BASE_TAG="${BASE_TAG:-2.11.3}"
FIX_COMMIT="${FIX_COMMIT:-}"
SUFFIX="${SUFFIX:-+rhlw.00001}"
WORK="${WORK:-/tmp/lightwell-backport}"
OUT="${OUT:-/srv/lightwell-mirror/packages}"

if [[ -z "${FIX_COMMIT}" ]]; then
    cat >&2 <<'USAGE'
FIX_COMMIT is required.

Find it in the GHSA advisory for the CVE you chose, then:

    FIX_COMMIT=<sha> ./scripts/make-lightwell-wheel.sh

Deliberately not defaulted: which commit you pick determines what the demo
claims to have fixed, and that should be a decision rather than a default.
USAGE
    exit 2
fi

rm -rf "${WORK}"
git clone --quiet "${REPO}" "${WORK}"
cd "${WORK}"
git checkout --quiet -b lightwell-backport "${BASE_TAG}"

echo "== cherry-picking ${FIX_COMMIT} onto ${BASE_TAG} =="
if ! git cherry-pick "${FIX_COMMIT}"; then
    echo >&2
    echo "Cherry-pick did not apply cleanly." >&2
    echo "Resolve minimally, or change candidate. Scope the change to the fix." >&2
    echo "Working tree left at ${WORK} for inspection." >&2
    exit 1
fi

echo "== diff against ${BASE_TAG} =="
git diff "${BASE_TAG}" --stat
echo
echo "Show this on camera in Act 3:"
echo "  git -C ${WORK} diff ${BASE_TAG}"
echo

# Stamp the Lightwell version. Jinja2 2.11 keeps __version__ in src/jinja2/__init__.py.
VERSION_FILE="src/jinja2/__init__.py"
if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "Cannot find ${VERSION_FILE} - adjust for the package you chose." >&2
    exit 1
fi
sed -i "s/__version__ = \"${BASE_TAG}\"/__version__ = \"${BASE_TAG}${SUFFIX}\"/" "${VERSION_FILE}"
grep -n "__version__" "${VERSION_FILE}"

echo "== building wheel =="
python3 -m pip install --quiet --upgrade build wheel setuptools
# --no-isolation avoids fetching build deps, which matters on a disconnected builder.
python3 -m build --wheel --no-isolation

mkdir -p "${OUT}"
cp dist/*.whl "${OUT}/"
echo
echo "Wheel placed in ${OUT}:"
ls -1 "${OUT}"
echo
echo "Next: ./scripts/serve-lightwell-mirror.sh"
