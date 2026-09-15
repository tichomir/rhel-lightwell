#!/usr/bin/bash
# Generate an SBOM for an image, in both formats TPA accepts.
#
#   ./scripts/make-sbom.sh quay.io/rhte2023/im-train:1.2
#   OUT=/srv/sboms ./scripts/make-sbom.sh quay.io/rhte2023/baseos:10.2
#
# Two formats because the two consumers differ:
#
#   SPDX 2.3 JSON   what Trusted Profile Analyzer ingests
#   CycloneDX JSON  what most scanners and policy engines prefer
#
# Both describe the same image. Generating both costs one extra second and
# saves an argument about formats in front of a customer.
#
# WHY AN SBOM IS WORTH SHOWING AT ALL IN THIS DEMO
#
# The remediation claim is "the patch scope is the fix and nothing else". That
# is asserted three times in the demo and provable once:
#
#   requirements.txt    one line changed        - what you INTENDED
#   patches/0001        22 lines in one file    - what the LIBRARY changed
#   SBOM diff           one component changed   - what actually SHIPPED
#
# The third is the only one a customer's security team can verify without
# trusting you, because it is derived from the artifact rather than the intent.
# It is also the input TPA needs to answer "which of my applications are
# affected", which is the follow-up conversation this demo earns.
set -euo pipefail

IMAGE="${1:-}"
if [[ -z "${IMAGE}" ]]; then
    echo "Usage: $0 <image-ref>   e.g. quay.io/rhte2023/im-train:1.2" >&2
    exit 2
fi

OUT="${OUT:-/srv/sboms}"
SYFT=$(command -v syft 2>/dev/null || echo /usr/local/bin/syft)
[[ -x "${SYFT}" ]] || { echo "syft not installed - see the build guide." >&2; exit 1; }

mkdir -p "${OUT}"
# One file per image ref, with the ref flattened into the name so two states of
# the same image never overwrite each other.
SLUG=$(printf '%s' "${IMAGE}" | tr -c 'a-zA-Z0-9._-' '-')

echo "== cataloguing ${IMAGE} =="
"${SYFT}" scan "${IMAGE}" -o "spdx-json=${OUT}/${SLUG}.spdx.json" \
                          -o "cyclonedx-json=${OUT}/${SLUG}.cdx.json" \
                          -q

for f in "${OUT}/${SLUG}.spdx.json" "${OUT}/${SLUG}.cdx.json"; do
    printf '  %-56s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

echo
echo "== what is in it =="
jq -r '"  components: \(.packages | length)"' "${OUT}/${SLUG}.spdx.json"
jq -r '[.packages[].externalRefs[]? | select(.referenceType=="purl") | .referenceLocator
        | capture("pkg:(?<t>[^/]+)/") | .t] | group_by(.) | map({t: .[0], n: length})
        | sort_by(-.n) | .[] | "    \(.t): \(.n)"' "${OUT}/${SLUG}.spdx.json"

echo
echo "== the demo subject, as the SBOM records it =="
jq -r '.packages[] | select(.name|ascii_downcase=="jinja2")
       | "  \(.name) \(.versionInfo)   \(.externalRefs[]? | select(.referenceType=="purl") | .referenceLocator)"' \
   "${OUT}/${SLUG}.spdx.json" | sort -u

cat <<NEXT

Feed the SPDX file to Trusted Profile Analyzer. Compare two of them with:
  ./scripts/diff-sbom.sh ${OUT}/<a>.spdx.json ${OUT}/<b>.spdx.json
NEXT
