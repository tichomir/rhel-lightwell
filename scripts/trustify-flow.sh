#!/usr/bin/bash
# The SBOM + VEX correlation scene, end to end and asserted.
#
#   ./scripts/trustify-flow.sh              load everything, then show the verdict
#   ./scripts/trustify-flow.sh gui          load for the GUI walk-through (no public feed)
#   ./scripts/trustify-flow.sh osv          add the public feed, so 1 becomes 2
#   ./scripts/trustify-flow.sh verdict      just re-print the verdict
#   ./scripts/trustify-flow.sh reset        wipe trustify and start empty
#
# Needs ./scripts/serve-trustify.sh to have been run once, and the SBOMs from
# ./scripts/make-sbom.sh plus the VEX from ./scripts/make-vex.sh.
#
# ############################################################################
# WHAT THIS PROVES, AND WHY IT IS THE RIGHT CLOSE FOR ACT 3
#
# Act 3 ends with the scanner still red and a promise that a VEX statement is
# where this is heading. That promise is the weakest moment in the demo,
# because up to that point everything has been demonstrated and that one thing
# is asserted.
#
# This closes it. Trustify is the upstream of Red Hat Trusted Profile Analyzer
# - trustification/rhtpa is the product's source and is currently byte-identical
# to guacsec/trustify - so this is not an analogue of the product, it is the
# product's engine with a different badge.
#
# The sequence and the measured result:
#
#   1. load both SBOMs                 3664 components each
#   2. load the public advisories      8 records from osv.dev, GHSA + PYSEC
#   3. ask about each build            ALL FOUR CVEs affected on BOTH builds,
#                                      including the remediated one
#   4. load the lab VEX                one document
#   5. ask again                       the two xmlattr CVEs now report FIXED
#                                      against the backport; the two sandbox
#                                      escapes still report affected
#
# Step 3 is the one worth pausing on. A third independent tool - after grype
# and after TPA - looks at 2.11.3+rhlw00001 and calls it vulnerable to all
# four. That is not three tools being wrong. It is PEP 440 working as written,
# and it is why an out-of-band assertion is the only mechanism available.
#
# ############################################################################
# THE TRAP THIS SCRIPT EXISTS TO PREVENT
#
# A VEX whose products sit in a flat product_tree.full_product_names array is
# accepted with 201 Created and correlates with NOTHING. No error, no warning.
# The document is valid CSAF and completely inert. Only the branches form
# links to a purl. If the verdict below shows no `fixed` rows, check that
# first - see the header of make-vex.sh.
set -uo pipefail

API="${API:-http://localhost:8080}"
SBOMS="${SBOMS:-/srv/sboms}"
VEX="${VEX:-/srv/vex/RHLAB-VEX-2026-0001.json}"
OSV="${OSV:-/tmp/osv}"
VULN_SBOM="${VULN_SBOM:-${SBOMS}/quay.io-rhte2023-im-train-1.1.spdx.json}"
FIXED_SBOM="${FIXED_SBOM:-${SBOMS}/quay.io-rhte2023-im-train-1.2.spdx.json}"
CVES="CVE-2024-22195 CVE-2024-34064 CVE-2024-56326 CVE-2025-27516"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

up() { # path file content-type label
    local code
    code=$(curl -sS -o /tmp/tf.out -w '%{http_code}' -X POST "${API}$1" \
           -H "Content-Type: $3" --data-binary @"$2" 2>/dev/null)
    printf '  %-36s HTTP %s\n' "$4" "${code}"
    [[ "${code}" == 2* ]]
}

verdict() { # expected number of `fixed` assertions (0 before the VEX, 2 after)
    python3 - "${API}" "${1:-2}" ${CVES} <<'PY'
import json, sys, urllib.request, collections
api, want_fixed, cves = sys.argv[1], int(sys.argv[2]), sys.argv[3:]

def get(p):
    with urllib.request.urlopen(api + p, timeout=120) as r:
        return json.load(r)

# Which purl is which build, straight from what trustify stored.
purls = {p["purl"]: p["uuid"]
         for p in get("/api/v2/purl?q=jinja2&limit=200").get("items", [])}
builds = [("vulnerable  2.11.3",          "pkg:pypi/jinja2@2.11.3"),
          ("remediated  2.11.3+rhlw00001", "pkg:pypi/jinja2@2.11.3+rhlw00001")]

BOLD, DIM, RED, GRN, OFF = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[0m"
print(f"\n{BOLD}  what every source says about each build{OFF}")
print(f"{DIM}  osv = the public feed. csaf = the lab VEX.{OFF}\n")

fixed_total = 0
for label, purl in builds:
    uu = purls.get(purl)
    print(f"  {BOLD}{label}{OFF}")
    if not uu:
        print(f"      {RED}purl not present in trustify{OFF}")
        continue
    # cve -> source -> status
    seen = collections.defaultdict(dict)
    for adv in get(f"/api/v2/purl/{uu}").get("advisories", []):
        typ = (adv.get("labels") or {}).get("type", "?")
        for s in adv.get("status", []):
            cve = s.get("vulnerability", {}).get("identifier")
            if cve in cves:
                seen[cve][typ] = s.get("status", "?")
    for cve in cves:
        osv = seen[cve].get("osv", "-")
        vex = seen[cve].get("csaf", "-")
        if vex == "fixed":
            fixed_total += 1
            col, note = GRN, "  <- the VEX overrides the feed"
        elif vex == "affected":
            col, note = "", ""
        else:
            col, note = DIM, "  (no VEX statement)"
        print(f"      {cve:18} osv={osv:10} vex={col}{vex:10}{OFF}{note}")
    print()

print(f"{BOLD}  assertions{OFF}")
ok = True
def check(label, got, want):
    global ok
    good = got == want
    ok = ok and good
    print(f"   {'ok  ' if good else 'FAIL'}  {label:46} {got}" + ("" if good else f"  want {want}"))

check("CVEs the VEX marks fixed on the backport", fixed_total, want_fixed)
print()
if not ok:
    if want_fixed:
        print(f"{RED}  Expected the VEX to mark two CVEs fixed and it marked {fixed_total}.")
        print(f"  The most likely cause by far: the VEX product_tree is the flat")
        print(f"  full_product_names form, which is valid CSAF and correlates with")
        print(f"  nothing at all. See the header of make-vex.sh.{OFF}")
    sys.exit(1)
if want_fixed == 0:
    print(f"{DIM}  Nothing is fixed yet, which is the point of this screen: the public")
    print(f"  feed alone cannot tell these two builds apart. A third tool - after")
    print(f"  grype and after TPA - calls the backport vulnerable to all four.{OFF}")
else:
    print(f"{GRN}  Two fixed, two still affected. The backport covers what it covers,")
    print(f"  and a machine agrees - from a document, not from narration.{OFF}")
PY
}

case "${1:-load}" in
reset)
    bold "wiping trustify"
    sudo systemctl stop trustify.service 2>/dev/null || sudo podman rm -f trustify 2>/dev/null
    sudo rm -rf /srv/trustify/data && sudo mkdir -p /srv/trustify/data
    sudo chown -R 1000:1000 /srv/trustify/data
    sudo systemctl start trustify.service 2>/dev/null || true
    for _ in $(seq 1 90); do
        curl -fsS -m2 "${API}/api/v2/sbom" >/dev/null 2>&1 && break
        sleep 1
    done
    echo "  empty and ready"
    exit 0
    ;;
verdict)
    verdict "${2:-2}"
    exit $?
    ;;
gui)
    # The state the GUI screens need: both SBOMs and the VEX, and NOT the
    # osv.dev feed. Without this the "Impacted SBOMs" column reads 2/2/2/2 and
    # the SBOMs list shows 4 on both builds, because the public feed's version
    # ranges still match the backport and nothing tells trustify that a vendor
    # statement about the same purl outranks them.
    #
    # This is a legitimate configuration, not a staged one - it is TPA fed by
    # the vendor's feed for vendor content. But SAY on camera that osv.dev is
    # not loaded, then load it with `osv` and let the numbers move. The gap is
    # the ask, and showing it is stronger than hiding it.
    "$0" reset >/dev/null
    bold "loading both SBOMs and the VEX (no public feed yet)"
    up /api/v2/sbom "${VULN_SBOM}"  application/octet-stream "im-train 1.1  vulnerable"
    up /api/v2/sbom "${FIXED_SBOM}" application/octet-stream "im-train 1.2  remediated"
    if [[ ! -r "${VEX}" ]]; then
        sudo cp /srv/vex/RHLAB-VEX-2026-0001.json /tmp/vex.json && sudo chmod 644 /tmp/vex.json
        VEX=/tmp/vex.json
    fi
    up /api/v2/advisory "${VEX}" application/json "$(basename "${VEX}")"
    cat <<'GUI'

Ready for the GUI walk-through. Three clicks, in this order:

  1. SBOMs          two rows, 1.1 and 1.2, 3664 components each
  2. Vulnerabilities   "Impacted SBOMs" reads  1, 1, 2, 2
  3. CVE-2024-22195 -> Related SBOMs   1.1 Affected, 1.2 Fixed

Then, to show the gap honestly:
  ./scripts/trustify-flow.sh osv     <- adds the public feed; 1 becomes 2

Do not type URLs - the UI drops the route on a hard load. Click through the
menu. And open on Vulnerabilities, not the Dashboard.
GUI
    exit 0
    ;;
osv)
    # Add the public feed on top of whatever is loaded, so the two xmlattr
    # CVEs go from "1 impacted SBOM" to 2 while the VEX still says fixed.
    bold "adding the public osv.dev feed"
    for f in "${OSV}"/GHSA-*.json "${OSV}"/PYSEC-*.json; do
        [[ -r "$f" ]] || continue
        up /api/v2/advisory "$f" application/json "$(basename "$f" .json)" || true
    done
    dim "  Reload the Vulnerabilities page: Impacted SBOMs is now 2,2,2,2."
    dim "  CVE-2024-22195 -> Related SBOMs still shows the Fixed row for 1.2."
    exit 0
    ;;
esac

curl -fsS -m5 "${API}/api/v2/sbom" >/dev/null 2>&1 || {
    echo "Trustify is not answering on ${API}. Run: sudo ./scripts/serve-trustify.sh" >&2
    exit 1
}

bold "1. the two SBOMs"
dim "  Same image, one component apart. 3664 components each."
up /api/v2/sbom "${VULN_SBOM}"  application/octet-stream "im-train 1.1  vulnerable" || exit 1
up /api/v2/sbom "${FIXED_SBOM}" application/octet-stream "im-train 1.2  remediated" || exit 1

bold "2. the public advisories"
dim "  Fetched from osv.dev - GHSA and PYSEC records for PyPI jinja2. This is"
dim "  the feed a real deployment gets from an importer on a schedule."
if [[ ! -d "${OSV}" ]] || ! compgen -G "${OSV}/GHSA-*.json" >/dev/null; then
    mkdir -p "${OSV}"
    curl -sS -X POST https://api.osv.dev/v1/query -H 'Content-Type: application/json' \
         -d '{"package":{"name":"jinja2","ecosystem":"PyPI"}}' -o "${OSV}/query.json"
    python3 - "${OSV}" ${CVES} <<'PY'
import json, sys, os
out, cves = sys.argv[1], sys.argv[2:]
for v in json.load(open(f"{out}/query.json")).get("vulns", []):
    ids = " ".join([v.get("id", "")] + v.get("aliases", []))
    if any(c in ids for c in cves):
        json.dump(v, open(f"{out}/{v['id']}.json", "w"))
PY
    rm -f "${OSV}/query.json"
fi
for f in "${OSV}"/GHSA-*.json "${OSV}"/PYSEC-*.json; do
    [[ -r "$f" ]] || continue
    up /api/v2/advisory "$f" application/json "$(basename "$f" .json)" || true
done

bold "3. before the VEX - ask trustify about both builds"
verdict 0 || true

bold "4. the lab VEX"
dim "  ONE document, authored in this lab. Not a Red Hat statement."
[[ -r "${VEX}" ]] || { sudo cp "${VEX}" /tmp/vex.json 2>/dev/null && VEX=/tmp/vex.json; }
if [[ ! -r "${VEX}" ]]; then
    sudo cp /srv/vex/RHLAB-VEX-2026-0001.json /tmp/vex.json && sudo chmod 644 /tmp/vex.json
    VEX=/tmp/vex.json
fi
up /api/v2/advisory "${VEX}" application/json "$(basename "${VEX}")" || exit 1

bold "5. after the VEX - ask again"
verdict 2
rc=$?

cat <<NEXT

On screen, in the UI: Vulnerabilities -> CVE-2024-22195 -> Related SBOMs.
Three rows. 1.1 appears once, Affected. 1.2 appears twice - Affected from the
public feed, Fixed from the VEX. That one table is this whole act.

Say that you wrote the VEX. Everything else here came from osv.dev and syft.
NEXT
exit ${rc}
