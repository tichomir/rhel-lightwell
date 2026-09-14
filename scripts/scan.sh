#!/usr/bin/bash
# Scan the application layer with grype.
#
# EXPECT A FALSE POSITIVE AFTER REMEDIATION. grype compares
# "2.11.3+rhlw00001" against "fixed in 3.1.x" and concludes you are still
# vulnerable. It has no way to know the fix exists, because the Lightwell
# security feed is not yet in the public vulnerability databases - that work is
# in progress with osv.dev and is the prerequisite for any scanner to
# understand .rhlw artifacts.
#
# Do not try to fix this. Handled properly it is the most credible ninety
# seconds in the recording:
#
#   1. Show the scanner still red. Explain why, plainly.
#   2. Show the test suite green - API compatibility and the CVE observable.
#   3. Show the VEX statement as where this is heading.
#   4. Land the point: your scanner report and your actual risk are not the
#      same document.
#
# An audience trusts a presenter who shows the tool disagreeing with them and
# explains why, far more than one whose every screen is green.
set -euo pipefail

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
    cat <<'USAGE'
Usage:
  ./scripts/scan.sh dir:/opt/app                 # on the running host
  ./scripts/scan.sh quay.io/<ns>/im-train:prod   # the image, from the builder
  ./scripts/scan.sh dir:.venv                    # a local development venv
USAGE
    exit 2
fi

command -v grype >/dev/null 2>&1 || {
    echo "grype not installed. See the build guide, section 1." >&2
    exit 1
}

echo "== grype ${TARGET} =="
grype "${TARGET}" --output table

echo
echo "== jinja2 findings only =="
grype "${TARGET}" --output json \
  | jq -r '.matches[]
           | select(.artifact.name | ascii_downcase == "jinja2")
           | "\(.vulnerability.id)  \(.vulnerability.severity)  installed=\(.artifact.version)  fixed-in=\(.vulnerability.fix.versions // ["none"] | join(","))"' \
  | sort -u
