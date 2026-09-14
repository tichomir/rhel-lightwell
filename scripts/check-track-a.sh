#!/usr/bin/bash
# Is the real Lightwell Remediated index usable for this demo yet?
#
#   ./scripts/check-track-a.sh
#
# Read-only. Changes nothing, writes nothing, and is safe to run repeatedly
# while you are waiting for entitlement.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST
#
# The Lightwell catalogue is deliberately not published, so coverage for a
# specific package at a specific version cannot be confirmed from any document -
# only by asking the index. And the one thing that absolutely must match between
# the lab mirror and the real index is the VERSION STRING, because it appears on
# the Status page and in the deck. If the real index publishes something other
# than +rhlw00001, the lab mirror has to be rebuilt to match or the two tracks
# stop being interchangeable on camera.
#
# This answers, in order:
#   1. Are credentials configured at all?
#   2. Does the index answer?
#   3. Is jinja2 in the catalogue?
#   4. Is the PINNED version there, and what is it called exactly?
#   5. Does it actually download?
#   6. Is there provenance to put on screen - signature, SBOM, attestation?
#
# Question 6 is the whole reason to want Track A. The fix in Track B is already
# genuine; what Track B cannot produce is Red Hat's attestation of it.
set -uo pipefail

INDEX="${INDEX:-https://packages.redhat.com/lightwell/python/remediated/simple/}"
PKG="${PKG:-jinja2}"
BASE_VER="${BASE_VER:-2.11.3}"
LAB_SUFFIX="${LAB_SUFFIX:-+rhlw00001}"
NETRC="${NETRC:-${HOME}/.netrc}"
MACHINE="${MACHINE:-packages.redhat.com}"

FAILS=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

echo "index:  ${INDEX}"
echo "target: ${PKG}==${BASE_VER}  (lab mirror publishes ${BASE_VER}${LAB_SUFFIX})"

head_ "1. credentials"
if [[ ! -f "${NETRC}" ]]; then
    fail "no ${NETRC}. Create it with the Registry Service Account from
        access.redhat.com - the login is of the form XXXXXXX|service-account-name:
          machine ${MACHINE} login <org>|<sa-name> password <token>
        then: chmod 600 ${NETRC}"
elif ! grep -q "machine[[:space:]]\+${MACHINE}" "${NETRC}"; then
    fail "${NETRC} exists but has no entry for ${MACHINE}"
else
    PERM=$(stat -c '%a' "${NETRC}")
    [[ "${PERM}" == "600" ]] && pass "entry for ${MACHINE} present, mode 600" \
        || warn "entry present but mode is ${PERM} - should be 600"
fi

head_ "2. does the index answer?"
# -n makes curl read ${NETRC}. Without credentials this is a 401, which is a
# different and much more useful answer than a timeout.
CODE=$(curl -sn -o /dev/null -m 20 -w '%{http_code}' "${INDEX}" 2>/dev/null || echo 000)
case "${CODE}" in
    200|301|302) pass "HTTP ${CODE} - reachable and authorised" ;;
    401|403) fail "HTTP ${CODE} - reachable but NOT authorised.
        This is the entitlement answer: the account does not have the
        Remediated repository. Ask customer service to add SKU LW00007." ;;
    404) fail "HTTP 404 - the index path is wrong. Confirm the URL in the
        Lightwell Network 'Get started' docs and re-run with INDEX=..." ;;
    000) fail "no response - DNS, egress or TLS. Check from this host:
        curl -v ${INDEX}" ;;
    *)   warn "HTTP ${CODE} - unexpected; inspect manually" ;;
esac

if (( FAILS > 0 )); then
    printf '\n\033[1m== verdict ==\033[0m\n'
    echo "  Track A is not available yet. Stay on Track B and caption the"
    echo "  remediation scene as a lab mirror. Nothing else in the demo changes."
    exit "${FAILS}"
fi

head_ "3. is ${PKG} in the catalogue?"
LISTING=$(curl -sn -m 30 "${INDEX}${PKG}/" 2>/dev/null)
if [[ -z "${LISTING}" ]]; then
    fail "empty listing for ${PKG} - not in the catalogue, or the URL shape differs"
else
    pass "${PKG} is listed"
    echo "  versions the index offers:"
    grep -o "${PKG}-[0-9][^\"<#]*" <<<"${LISTING}" | sed 's/^/    /' | sort -u | head -20
fi

head_ "4. THE VERSION STRING - the one that must match the deck"
FOUND=$(grep -o "${PKG}-${BASE_VER}[^\"<#]*" <<<"${LISTING}" | sed "s/^${PKG}-//;s/-py[0-9].*//;s/\.whl$//" | sort -u | head -5)
if [[ -z "${FOUND}" ]]; then
    fail "${BASE_VER} is NOT in the catalogue.
        Coverage is per package AND per version, so this is the likely failure.
        Check Lightwell Lens on console.redhat.com, and ask whether a backport
        for this version can be requested. Until then, stay on Track B."
else
    echo "  real index publishes:"
    sed 's/^/    /' <<<"${FOUND}"
    echo "  lab mirror publishes:"
    echo "    ${BASE_VER}${LAB_SUFFIX}"
    if grep -qxF "${BASE_VER}${LAB_SUFFIX}" <<<"${FOUND}"; then
        pass "they MATCH - the two tracks are interchangeable on camera"
    else
        REAL=$(head -1 <<<"${FOUND}")
        warn "they DIFFER. Rebuild the lab mirror to match before recording:
          SUFFIX=${REAL#${BASE_VER}} sudo ./scripts/make-lightwell-wheel.sh
          sudo ./scripts/serve-lightwell-mirror.sh
        and update requirements.txt, the deck and RUNBOOK.md to '${REAL}'.
        Note app/sysinfo.py only greps for 'rhlw', so the Status page and the
        test suite keep working either way."
    fi
fi

head_ "5. does it download?"
TMP=$(mktemp -d)
if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
    PIP=$(command -v pip3 || command -v pip)
    if "${PIP}" download "${PKG}==${BASE_VER}" -d "${TMP}" --no-deps \
         --index-url "${INDEX}" >/dev/null 2>&1; then
        pass "downloaded: $(ls -1 "${TMP}" | head -1)"
        echo
        echo "  Note this used the PLAIN '==${BASE_VER}' specifier. PEP 440 lets"
        echo "  that match a local version, so the existing pin picks up the"
        echo "  backport with no edit at all - verified on the lab mirror."
    else
        warn "pip download failed. Often netrc auth not reaching pip; try
          pip download '${PKG}==${BASE_VER}' -d /tmp/x --no-deps --index-url ${INDEX} -v"
    fi
else
    warn "no pip on this host - run this check inside a python container"
fi

head_ "6. provenance - THE reason to want Track A"
echo "  Track B produces a genuine fix with no attestation. Track A should add"
echo "  a signature, an SBOM and a SLSA L3 provenance statement, and those are"
echo "  what Act 3 puts on screen."
echo
echo "  Artifacts alongside the wheel, if the index publishes them:"
for ext in .asc .sig .sigstore .intoto.jsonl .spdx.json .cdx.json; do
    printf '    %-16s ' "${ext}"
    grep -o "${PKG}-${BASE_VER}[^\"<#]*${ext}" <<<"${LISTING}" | head -1 || echo "not listed"
done
echo
echo "  If none are listed here they may be served out of band - the Lightwell"
echo "  Network 'Get started' docs are the authority. Find out BEFORE filming:"
echo "  'show the signature and provenance' is in the Act 3 script and Track B"
echo "  cannot deliver it."
rm -rf "${TMP}"

printf '\n\033[1m== verdict ==\033[0m\n'
if (( FAILS == 0 )); then
    printf '  \033[32mTrack A looks usable.\033[0m Switch with: ./scripts/switch-track.sh a\n'
else
    printf '  \033[31m%d blocking problem(s).\033[0m Stay on Track B.\n' "${FAILS}"
fi
exit "${FAILS}"
