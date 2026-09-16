#!/usr/bin/bash
# Generate a CSAF 2.0 VEX document for the backported build.
#
#   ./scripts/make-vex.sh
#   OUT=/srv/vex ./scripts/make-vex.sh
#
# ############################################################################
# READ THIS BEFORE PUTTING THE OUTPUT ON CAMERA
#
# This document is authored HERE, in this lab. Red Hat does not publish VEX for
# Lightwell content yet - that missing public feed is precisely the limitation
# Act 3 admits to. So this is the SHAPE of the statement Red Hat will publish,
# not a statement Red Hat has made.
#
# Caption it exactly as carefully as the Track B index, for the same reason: a
# recording gets forwarded, and a locally-authored vendor assertion that looks
# official is the one thing in this demo that could genuinely mislead someone.
# ############################################################################
#
# WHY THIS EXISTS AT ALL
#
# Verified with the packaging library: PEP 440 gives a local version segment no
# ordering weight against a different release. So 2.11.3+rhlw00001 compares as
# 2.11.3 and sits inside every advisory range - <3.1.3 through <3.1.6:
#
#   Version("2.11.3+rhlw00001") < Version("3.1.5")   ->  True
#
# That is CORRECT per the spec. grype, Trusted Profile Analyzer, osv.dev and
# every other compliant tool will therefore report the remediated build as
# affected, and no version string can ever fix that. An out-of-band assertion
# is the only mechanism available, which is what VEX is.
#
# THE PART THAT MAKES THIS HONEST
#
# The backport in patches/0001 touches ONE function - do_xmlattr. So it fixes
# the two xmlattr CVEs and nothing else:
#
#   CVE-2024-22195   xmlattr, space in attribute name      FIXED by the backport
#   CVE-2024-34064   xmlattr, further characters           FIXED by the backport
#   CVE-2024-56326   sandbox escape via str.format         STILL AFFECTED
#   CVE-2025-27516   sandbox escape via |attr filter       STILL AFFECTED
#
# So this VEX asserts `fixed` for two and `known_affected` for two. Asserting
# all four would be a false vendor statement, in a demo whose entire credibility
# rests on not doing that.
#
# It also makes a better scene: two findings flip, two stay red, and the two
# that stay are the sandbox escapes - including the CVSS 7.8. "Partial
# remediation, honestly labelled" is what real vendor VEX looks like.
#
# WHY THE PRODUCT TREE USES `branches` AND NOT `full_product_names`
#
# Both are valid CSAF 2.0. Only one of them correlates.
#
# Verified against a local trustify 0.4.20 - the same engine Trusted Profile
# Analyzer is built from: a VEX whose products sit in a flat
# `product_tree.full_product_names` array is INGESTED WITHOUT ERROR - 201
# Created, issuer parsed, all four CVEs listed - and then attaches to nothing.
# The purl never links, so no SBOM finding is ever affected by it. There is no
# warning anywhere; the document simply sits there being correct and inert.
#
# Moving the same two products into a vendor -> product_version branch, each
# carrying the same `product_identification_helper.purl`, made it correlate
# immediately. Measured, on the remediated build:
#
#   before      4 CVEs reported affected by this VEX
#   after       2 - the two xmlattr CVEs dropped off, marked fixed
#
# So if a VEX ever appears to upload cleanly and change nothing, this is the
# first thing to check. It is almost certainly why an earlier upload of this
# document to TPA produced no visible change.
set -euo pipefail

OUT="${OUT:-/srv/vex}"
PKG="${PKG:-jinja2}"
VULN_VER="${VULN_VER:-2.11.3}"
FIXED_VER="${FIXED_VER:-2.11.3+rhlw00001}"

# purl version encoding. syft writes the '+' percent-encoded in the SBOM, but
# trustify normalises both forms to a literal '+' when it stores the purl -
# VERIFIED against a local trustify 0.4.20: an SBOM containing
# pkg:pypi/jinja2@2.11.3%2Brhlw00001 is stored as pkg:pypi/jinja2@2.11.3+rhlw00001,
# and a VEX using the literal form matches it. So the literal form is the
# default; override if some other ingesting tool disagrees.
FIXED_PURL_VER="${FIXED_PURL_VER:-2.11.3+rhlw00001}"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ID="RHLAB-VEX-$(date -u +%Y)-0001"
mkdir -p "${OUT}"
FILE="${OUT}/${ID}.json"

cat > "${FILE}" <<JSON
{
  "document": {
    "category": "csaf_vex",
    "csaf_version": "2.0",
    "title": "Lab-authored VEX: ${PKG} ${FIXED_VER} (backported xmlattr fix)",
    "publisher": {
      "category": "other",
      "name": "rh-lab - LOCALLY AUTHORED, NOT A RED HAT STATEMENT",
      "namespace": "https://github.com/tichomir/rhel-lightwell"
    },
    "tracking": {
      "id": "${ID}",
      "status": "final",
      "version": "1",
      "initial_release_date": "${NOW}",
      "current_release_date": "${NOW}",
      "generator": {
        "engine": { "name": "rhel-lightwell/scripts/make-vex.sh", "version": "1" }
      },
      "revision_history": [
        { "number": "1", "date": "${NOW}", "summary": "Initial lab-authored assertion." }
      ]
    },
    "notes": [
      {
        "category": "legal_disclaimer",
        "title": "This is not a Red Hat statement",
        "text": "Authored in a demonstration lab. Red Hat does not currently publish VEX for Lightwell Network content; the public security feed that would carry it is still in progress. This document illustrates the SHAPE of such a statement and must not be treated as a vendor assertion."
      },
      {
        "category": "general",
        "title": "Why a VEX statement is required here",
        "text": "PEP 440 gives a local version segment no ordering weight against a different release, so ${FIXED_VER} compares as ${VULN_VER} and falls inside every published advisory range for this package. Any specification-compliant scanner will therefore report it as affected. No version string can convey that a backport has been applied; an out-of-band assertion is the only available mechanism."
      },
      {
        "category": "general",
        "title": "Scope of the backport",
        "text": "The backport modifies a single function, do_xmlattr, and therefore addresses only the two attribute-name injection issues. The two sandbox-escape vulnerabilities in the same version are NOT addressed and are reported here as still affected."
      }
    ]
  },
  "product_tree": {
    "branches": [
      {
        "category": "vendor",
        "name": "rh-lab (LOCALLY AUTHORED, NOT A RED HAT STATEMENT)",
        "branches": [
          {
            "category": "product_version",
            "name": "${PKG} ${VULN_VER}",
            "product": {
              "product_id": "CSAFPID-0001",
              "name": "${PKG} ${VULN_VER} (upstream, unpatched)",
              "product_identification_helper": { "purl": "pkg:pypi/${PKG}@${VULN_VER}" }
            }
          },
          {
            "category": "product_version",
            "name": "${PKG} ${FIXED_VER}",
            "product": {
              "product_id": "CSAFPID-0002",
              "name": "${PKG} ${FIXED_VER} (lab backport)",
              "product_identification_helper": { "purl": "pkg:pypi/${PKG}@${FIXED_PURL_VER}" }
            }
          }
        ]
      }
    ]
  },
  "vulnerabilities": [
    {
      "cve": "CVE-2024-22195",
      "title": "xmlattr filter accepts a space in an attribute name",
      "notes": [
        { "category": "description", "text": "The xmlattr filter did not validate attribute names. A key containing whitespace terminates the attribute name early, allowing an additional attribute to be injected into the rendered markup." },
        { "category": "details", "text": "Addressed in ${FIXED_VER} by rejecting invalid characters in attribute names, derived from upstream commit 7dd3680e." }
      ],
      "product_status": {
        "known_affected": ["CSAFPID-0001"],
        "fixed": ["CSAFPID-0002"]
      },
      "remediations": [
        {
          "category": "vendor_fix",
          "details": "Use ${FIXED_VER}, which carries the backported fix with no API change.",
          "product_ids": ["CSAFPID-0001"]
        }
      ]
    },
    {
      "cve": "CVE-2024-34064",
      "title": "xmlattr filter accepts further invalid characters in an attribute name",
      "notes": [
        { "category": "description", "text": "Extends CVE-2024-22195 to the solidus, greater-than and equals characters, which can likewise terminate an attribute name early." },
        { "category": "details", "text": "Addressed in ${FIXED_VER} by the same cumulative check, derived from upstream commit d6550307." }
      ],
      "product_status": {
        "known_affected": ["CSAFPID-0001"],
        "fixed": ["CSAFPID-0002"]
      },
      "remediations": [
        {
          "category": "vendor_fix",
          "details": "Use ${FIXED_VER}, which carries the backported fix with no API change.",
          "product_ids": ["CSAFPID-0001"]
        }
      ]
    },
    {
      "cve": "CVE-2024-56326",
      "title": "Sandbox escape through an indirect reference to str.format",
      "notes": [
        { "category": "description", "text": "A sandbox escape permitting execution of arbitrary Python code. Not related to the xmlattr filter." },
        { "category": "details", "text": "NOT addressed by this backport, which modifies only do_xmlattr. Both products remain affected. This is the highest-severity issue in this set." }
      ],
      "product_status": {
        "known_affected": ["CSAFPID-0001", "CSAFPID-0002"]
      },
      "remediations": [
        {
          "category": "none_available",
          "details": "No backport is available in the 2.11.x line. Upstream addresses this in 3.1.5.",
          "product_ids": ["CSAFPID-0001", "CSAFPID-0002"]
        }
      ]
    },
    {
      "cve": "CVE-2025-27516",
      "title": "Sandbox escape through the attr filter",
      "notes": [
        { "category": "description", "text": "A sandbox escape via the |attr filter. Not related to the xmlattr filter." },
        { "category": "details", "text": "NOT addressed by this backport, which modifies only do_xmlattr. Both products remain affected." }
      ],
      "product_status": {
        "known_affected": ["CSAFPID-0001", "CSAFPID-0002"]
      },
      "remediations": [
        {
          "category": "none_available",
          "details": "No backport is available in the 2.11.x line. Upstream addresses this in 3.1.6.",
          "product_ids": ["CSAFPID-0001", "CSAFPID-0002"]
        }
      ]
    }
  ]
}
JSON

echo "== wrote ${FILE} =="
jq empty "${FILE}" && echo "  JSON: well-formed"

# Check the fields the CSAF 2.0 VEX profile requires, so an ingest failure is
# not the first time you learn something is missing.
echo
echo "== CSAF 2.0 required-field check =="
jq -r '
  def has(p): if p then "  ok    " else "  MISS  " end;
  [ has(.document.category == "csaf_vex")            + "document.category = csaf_vex",
    has(.document.csaf_version == "2.0")             + "document.csaf_version = 2.0",
    has(.document.title != null)                     + "document.title",
    has(.document.publisher.category != null)        + "document.publisher.category",
    has(.document.publisher.name != null)            + "document.publisher.name",
    has(.document.publisher.namespace != null)       + "document.publisher.namespace",
    has(.document.tracking.id != null)               + "document.tracking.id",
    has(.document.tracking.status != null)           + "document.tracking.status",
    has(.document.tracking.version != null)          + "document.tracking.version",
    has(.document.tracking.initial_release_date)     + "document.tracking.initial_release_date",
    has(.document.tracking.current_release_date)     + "document.tracking.current_release_date",
    has((.document.tracking.revision_history|length) > 0) + "document.tracking.revision_history",
    has((.product_tree.branches|length) > 0)              + "product_tree.branches",
    has(all(.product_tree.branches[].branches[].product.product_identification_helper.purl; . != null))
                                                          + "every product carries a purl",
    has((.vulnerabilities|length) > 0)               + "vulnerabilities",
    has(all(.vulnerabilities[]; .product_status != null)) + "every vulnerability has product_status",
    has(all(.vulnerabilities[]; (.remediations|length) > 0)) + "every vulnerability has a remediation"
  ] | .[]' "${FILE}"

echo
echo "== what this document asserts =="
jq -r '.vulnerabilities[]
       | "  \(.cve)  fixed=\(.product_status.fixed // [] | length)  affected=\(.product_status.known_affected // [] | length)   \(.title)"' "${FILE}"

cat <<NEXT

Upload to Trusted Profile Analyzer as an ADVISORY, not through the SBOM path -
CSAF VEX is an advisory document in TPA's model. Ingest it alongside the SBOM
for the remediated image, or there is nothing for it to correlate against.

Expected: the two xmlattr CVEs move to fixed for ${FIXED_VER}; the two sandbox
escapes stay affected for BOTH versions - including the CVSS 7.8.

That partial result is the point. A blanket all-clear would be a false vendor
statement, and "the backport covers what it covers" is what real VEX looks
like. Say on camera that you wrote this document.

The narration for this scene - what an SBOM and a VEX are in one breath each,
and which half of it is real today - is in RUNBOOK.md under "The story to tell:
two SBOMs and a VEX". Read it before the take; this document lands badly if the
authorship is left ambiguous.
NEXT
