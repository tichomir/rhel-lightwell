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
# - so a local version is used instead: "2.11.3+rhlw00001". Confirm the exact
# string the real index uses before recording, and match it here so the two
# tracks are visually interchangeable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${REPO:-https://github.com/pallets/jinja.git}"
BASE_TAG="${BASE_TAG:-2.11.3}"
FIX_COMMIT="${FIX_COMMIT:-}"
# ORDER MATTERS. 0001 and 0002 both touch filters.py; applied the other way
# round, 0002's do_attr hunk does not apply. Between them the four CVEs in this
# package are closed - see each patch header for the upstream commits and the
# verification.
PATCHES=(
    "${ROOT}/patches/0001-xmlattr-reject-invalid-attribute-names.patch"
    "${ROOT}/patches/0002-sandbox-escapes-via-str-format-and-attr-filter.patch"
)
WORK="${WORK:-/tmp/lightwell-backport}"
OUT="${OUT:-/srv/lightwell-mirror/packages}"

# PEP 440 normalises numeric local-version segments, so "+rhlw.00001" is
# installed and displayed as "+rhlw.1" - the leading zeros are stripped and you
# cannot keep them. Only a segment that is not purely numeric survives intact,
# which is why the default has no separating dot:
#
#   +rhlw.00001  -> 2.11.3+rhlw.1        (zeros lost)
#   +rhlw00001   -> 2.11.3+rhlw00001     (kept)
#
# This is visible on the Status page and in `pip show`, so it must match what
# the real Remediated index publishes. CONFIRM THAT STRING AGAINST TRACK A
# BEFORE RECORDING and set SUFFIX to match.
SUFFIX="${SUFFIX:-+rhlw00001}"

rm -rf "${WORK}"
git clone --quiet "${REPO}" "${WORK}"
cd "${WORK}"
git checkout --quiet -b lightwell-backport "${BASE_TAG}"

# Two routes to the same four-line change.
#
# FIX_COMMIT cherry-picks straight from upstream. For jinja2 this CONFLICTS:
# 3.1.x carries type annotations, f-strings and pass_eval_context where 2.11.3
# has evalcontextfilter and iteritems(). The conflicts are era-related, not
# semantic, but they are real - so the default route applies the pre-resolved
# patch in patches/, whose header records the upstream commits it derives from.
if [[ -n "${FIX_COMMIT}" ]]; then
    echo "== cherry-picking ${FIX_COMMIT} onto ${BASE_TAG} =="
    if ! git cherry-pick "${FIX_COMMIT}"; then
        echo >&2
        echo "Cherry-pick conflicted (expected for jinja2 - see patches/)." >&2
        echo "Falling back to the pre-resolved patch." >&2
        git cherry-pick --abort
        FIX_COMMIT=""
    fi
fi

if [[ -z "${FIX_COMMIT}" ]]; then
    for P in "${PATCHES[@]}"; do
        [[ -f "${P}" ]] || { echo "Patch not found: ${P}" >&2; exit 1; }
        echo "== applying $(basename "${P}") onto ${BASE_TAG} =="
        git apply --verbose "${P}" || {
            echo "Patch did not apply. Is BASE_TAG=${BASE_TAG} right, and are" >&2
            echo "the patches being applied in order?" >&2
            echo "Working tree left at ${WORK} for inspection." >&2
            exit 1
        }
    done
    # Left uncommitted on purpose: `git diff ${BASE_TAG}` below then shows the
    # whole backport straight from the working tree, and the script does not
    # need a configured git identity on the builder.
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
# Build tooling goes in a throwaway venv, never into the system interpreter.
#
# On RHEL the system setuptools is an RPM with no dist-info RECORD file, so
# `pip install --upgrade setuptools` fails with "Cannot uninstall setuptools:
# the package's contents are unknown" and takes the whole build with it. A venv
# sidesteps it entirely and makes the build independent of whatever the host
# happens to have installed.
BUILD_VENV="${BUILD_VENV:-${WORK}/.build-venv}"
python3 -m venv "${BUILD_VENV}"
"${BUILD_VENV}/bin/pip" install --quiet --upgrade pip build wheel setuptools

# --no-isolation builds against the venv's own setuptools rather than fetching
# build deps again, which also matters on a disconnected builder.
"${BUILD_VENV}/bin/python" -m build --wheel --no-isolation

mkdir -p "${OUT}"
cp dist/*.whl "${OUT}/"
echo
echo "Wheel placed in ${OUT}:"
ls -1 "${OUT}"
echo
echo "Next: ./scripts/serve-lightwell-mirror.sh"
