#!/usr/bin/bash
# Scan with grype, and present it the way the demo needs it.
#
#   ./scripts/scan.sh quay.io/<ns>/im-train:prod          # the whole image
#   ./scripts/scan.sh quay.io/<ns>/im-train:prod app      # only the app's deps
#   ./scripts/scan.sh quay.io/<ns>/im-train:prod triage   # the 21,000-line view
#   ./scripts/scan.sh quay.io/<ns>/im-train:prod jinja2   # just the subject
#
# WHAT A REAL SCAN OF THIS IMAGE ACTUALLY LOOKS LIKE
#
# Measured on im-train built from rhel-bootc:10.2 - roughly 21,000 matches:
#
#   fix.state=not-fixed   ~20,000   Red Hat has assessed these. No fix yet.
#   fix.state=wont-fix      ~820    Assessed as not warranting a fix.
#   fix.state=fixed          ~190   Actually actionable.
#
# So do NOT say "the scanner report on the OS is clean" on camera. It is not.
# It is 21,000 lines long, and a viewer who has ever run a scanner knows it.
#
# The honest version is stronger anyway: of 21,000 findings, 99% cannot be
# acted on, most of the remainder are Go modules where grype reads the upstream
# version out of a Red Hat-built binary and cannot see the backport, and about
# twenty are real "rebuild on a newer batch" items. That is the same failure
# mode this demo is about to demonstrate with Lightwell - a scanner that cannot
# tell "the vendor fixed this" from "this is still broken" - except here it is
# happening to Red Hat's own packages, which makes the point without anyone
# having to take your word for it.
#
# AND THE CONTRAST WORTH POINTING AT
#
# The app layer carries two kinds of finding, which is lucky:
#
#   starlette 0.38.6   High findings, fixed in 0.40.x. A minor bump. Do it.
#   jinja2 2.11.3      Medium findings, fixed only in 3.1.x. A migration.
#
# One is "just upgrade it" and one is not, on the same screen, in the same
# application. That is the whole Lightwell argument without a slide.
#
# NOTE ON SEVERITY: the jinja2 findings are Medium (CVSS 5.4), except
# CVE-2024-56326 at 7.8 - the sandbox escape, and the serious one. If the deck
# says "high severity", fix the deck: the terminal will contradict it.
set -uo pipefail

TARGET="${1:-}"
VIEW="${2:-summary}"

if [[ -z "${TARGET}" ]]; then
    sed -n '3,9p' "$0" | sed 's/^# \?//'
    exit 2
fi

GRYPE=$(command -v grype 2>/dev/null || { [[ -x /usr/local/bin/grype ]] && echo /usr/local/bin/grype; })
[[ -n "${GRYPE}" ]] || { echo "grype not installed - see the build guide, section 1." >&2; exit 1; }

CACHE="${CACHE:-/tmp/grype-$(echo "${TARGET}" | tr -c 'a-zA-Z0-9' '-').json}"
if [[ -s "${CACHE}" && -z "${RESCAN:-}" ]]; then
    echo "== using cached scan: ${CACHE}  (RESCAN=1 to force) =="
else
    echo "== scanning ${TARGET} - this takes a couple of minutes =="
    "${GRYPE}" "${TARGET}" --output json > "${CACHE}" 2>/dev/null
fi

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

case "${VIEW}" in

summary)
    bold "total matches"
    jq -r '"  \(.matches|length)"' "${CACHE}"

    bold "by severity"
    jq -r '[.matches[].vulnerability.severity] | group_by(.)
           | map({s:.[0], n:length}) | sort_by(-.n) | .[]
           | "  \(.s|ascii_downcase): \(.n)"' "${CACHE}"

    bold "by fix state - the number that matters"
    jq -r '[.matches[].vulnerability.fix.state] | group_by(.)
           | map({s:.[0], n:length}) | sort_by(-.n) | .[]
           | "  \(.s): \(.n)"' "${CACHE}"
    echo
    echo "  Only the 'fixed' row is actionable. Everything else is Red Hat"
    echo "  saying either 'no fix yet' or 'this does not warrant one'."

    bold "actionable findings by ecosystem"
    jq -r '[.matches[] | select(.vulnerability.fix.state=="fixed")]
           | group_by(.artifact.type) | map({t:.[0].artifact.type, n:length})
           | sort_by(-.n) | .[] | "  \(.t): \(.n)"' "${CACHE}"
    ;;

app)
    # Only what came from requirements.txt. This is the Act 2 screen: it is
    # short, it is entirely the application's own dependencies, and none of it
    # is anything a RHEL subscription has ever covered.
    bold "application dependencies only (/opt/app/venv)"
    jq -r '.matches[]
           | select(.artifact.type=="python")
           | select(.artifact.locations[0].path | test("/opt/app"))
           | "  \(.vulnerability.severity|.[0:6])  \(.artifact.name) \(.artifact.version)
       \(.vulnerability.id)  \(.relatedVulnerabilities//[]|map(.id)|join(","))
       fix: \(.vulnerability.fix.versions|join(", "))"' "${CACHE}" | sort -u
    echo
    echo "  Read the 'fix' column twice. starlette's fix is a minor bump."
    echo "  jinja2's is the 3.1.x line - a migration, not an upgrade."
    ;;

triage)
    bold "what you would actually hand a security team"
    jq -r '"  total:      \(.matches|length)"' "${CACHE}"
    jq -r '"  actionable: \([.matches[]|select(.vulnerability.fix.state=="fixed")]|length)"' "${CACHE}"
    jq -r '"  no fix:     \([.matches[]|select(.vulnerability.fix.state=="not-fixed")]|length)"' "${CACHE}"
    jq -r '"  wont fix:   \([.matches[]|select(.vulnerability.fix.state=="wont-fix")]|length)"' "${CACHE}"

    bold "actionable RPM findings - genuine 'rebuild on a newer batch' items"
    jq -r '.matches[]
           | select(.vulnerability.fix.state=="fixed" and .artifact.type=="rpm")
           | "  \(.vulnerability.severity|.[0:6])  \(.artifact.name) \(.artifact.version)
       \(.vulnerability.id) -> \(.vulnerability.fix.versions|join(","))"' "${CACHE}" | sort -u

    bold "actionable Go findings - mostly NOT real"
    jq -r '[.matches[]|select(.vulnerability.fix.state=="fixed" and .artifact.type=="go-module")]|length
           | "  \(.) findings"' "${CACHE}"
    echo "  grype reads the upstream module version out of Red Hat-built binaries"
    echo "  (podman, buildah, runc, the Go stdlib) and cannot see that the fix was"
    echo "  backported without changing that version string."
    echo
    echo "  That is EXACTLY what is about to happen to the Lightwell artifact."
    echo "  Same tool, same blind spot, Red Hat's own packages. Say this out loud."
    ;;

jinja2|subject)
    bold "the demo subject"
    jq -r '.matches[]
           | select(.artifact.name|ascii_downcase=="jinja2")
           | "  \(.vulnerability.id)  \(.relatedVulnerabilities//[]|map(.id)|join(","))
       severity: \(.vulnerability.severity)   cvss: \(([.vulnerability.cvss[]?.metrics.baseScore]|max) // "n/a")
       installed: \(.artifact.version)   fixed in: \(.vulnerability.fix.versions|join(", "))"' "${CACHE}" | sort -u
    echo
    echo "  Every fix is in the 3.1.x line. There is no 2.11.x that resolves these,"
    echo "  which is the entire reason this demo exists."
    echo
    echo "  AFTER REMEDIATION THIS OUTPUT DOES NOT CHANGE. grype compares"
    echo "  2.11.3+rhlw00001 against 'fixed in 3.1.x' and still reports you"
    echo "  vulnerable. That is expected, it is not a bug, and it is the most"
    echo "  credible ninety seconds in the recording. Do not try to fix it."
    ;;

*)
    echo "Unknown view '${VIEW}'. Use: summary | app | triage | jinja2" >&2
    exit 2
    ;;
esac
