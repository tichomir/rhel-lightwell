#!/usr/bin/bash
# Compare two SBOMs and show what actually changed between two shipped images.
#
#   ./scripts/diff-sbom.sh /srv/sboms/<before>.spdx.json /srv/sboms/<after>.spdx.json
#
# This is the strongest verification available in the demo, because it is
# derived from the artifacts rather than from anyone's description of them. A
# customer's security team can run it themselves against the public images.
#
# THE SCENE THIS IS FOR
#
# Run it twice, on one screen:
#
#   baseos 10.1 -> 10.2        the OS act: hundreds of components moved
#   im-train vulnerable -> remediated   the app act: ONE component moved
#
# Same command, same promotion gate, same rollback - and two blast radiuses
# that differ by three orders of magnitude. That is the whole argument for why
# a dependency fix is safer to ship than an OS upgrade, and it is a fact about
# the images rather than a claim about the process.
#
# It is also the honest check on "the patch scope is the fix and nothing else".
# If a remediated build shows more than one changed component, that sentence is
# false and you want to know before a customer does.
set -euo pipefail

A="${1:-}"; B="${2:-}"
if [[ -z "${A}" || -z "${B}" ]]; then
    echo "Usage: $0 <before.spdx.json> <after.spdx.json>" >&2
    exit 2
fi
for f in "${A}" "${B}"; do
    [[ -r "$f" ]] || { echo "Cannot read ${f}" >&2; exit 1; }
done

# name<TAB>version, sorted and deduplicated, so comm can do the set arithmetic.
#
# Excludes the package the document DESCRIBES - the image itself. syft
# catalogues it as a package alongside its contents, so an image whose only
# real change is one library reports TWO changed components: the library, and
# the image's own tag moving 1.1 -> 1.2.
#
# That inflation lands squarely on the claim this diff exists to prove, so the
# self-reference is identified properly via the SPDX DESCRIBES relationship
# rather than pattern-matched out of the name.
extract() {
    jq -r '
      [.relationships[]? | select(.relationshipType == "DESCRIBES") | .relatedSpdxElement] as $roots
      | .packages[]
      | select(.name != null)
      | select(($roots | index(.SPDXID // "")) == null)
      | "\(.name)\t\(.versionInfo // "-")"' "$1" | sort -u
}

TMP=$(mktemp -d); trap 'rm -rf "${TMP}"' EXIT
extract "${A}" > "${TMP}/a"
extract "${B}" > "${TMP}/b"

printf '\033[1m== %s ==\033[0m\n' "component counts"
printf '  before  %5s  %s\n' "$(wc -l < "${TMP}/a")" "$(basename "${A}")"
printf '  after   %5s  %s\n' "$(wc -l < "${TMP}/b")" "$(basename "${B}")"

# A package whose NAME appears on both sides but with a different version is a
# change, not an add plus a remove. Treating it as two lines triples the
# apparent size of the delta and makes a one-component change look like three.
comm -23 "${TMP}/a" "${TMP}/b" | cut -f1 | sort -u > "${TMP}/only_a"
comm -13 "${TMP}/a" "${TMP}/b" | cut -f1 | sort -u > "${TMP}/only_b"
comm -12 "${TMP}/only_a" "${TMP}/only_b" > "${TMP}/changed"
comm -23 "${TMP}/only_a" "${TMP}/changed" > "${TMP}/removed"
comm -13 "${TMP}/only_b" "${TMP}/changed" > "${TMP}/added"

N_CHANGED=$(wc -l < "${TMP}/changed")
N_ADDED=$(wc -l < "${TMP}/added")
N_REMOVED=$(wc -l < "${TMP}/removed")
TOTAL=$(( N_CHANGED + N_ADDED + N_REMOVED ))

printf '\n\033[1m== %s ==\033[0m\n' "delta"
printf '  version changed  %5s\n' "${N_CHANGED}"
printf '  added            %5s\n' "${N_ADDED}"
printf '  removed          %5s\n' "${N_REMOVED}"
printf '  \033[1mtotal affected   %5s\033[0m\n' "${TOTAL}"

show() { # file label colour limit
    [[ -s "$1" ]] || return 0
    printf '\n\033[1m== %s ==\033[0m\n' "$2"
    head -n "$4" "$1" | while read -r name; do
        va=$(awk -F'\t' -v n="${name}" '$1==n{print $2}' "${TMP}/a" | head -1)
        vb=$(awk -F'\t' -v n="${name}" '$1==n{print $2}' "${TMP}/b" | head -1)
        printf "  \033[%sm%-34s %s -> %s\033[0m\n" "$3" "${name}" "${va:--}" "${vb:--}"
    done
    n=$(wc -l < "$1")
    (( n > $4 )) && printf '  ... and %s more\n' "$(( n - $4 ))"
    return 0
}
show "${TMP}/changed" "version changed" 33 25
show "${TMP}/added"   "added"           32 15
show "${TMP}/removed" "removed"         31 15

echo
if (( TOTAL == 1 )); then
    printf '\033[32m  One component moved. That is the patch scope, from the shipped\n'
    printf '  artifact rather than from anyone saying so.\033[0m\n'
elif (( TOTAL <= 5 )); then
    printf '\033[32m  %s components moved - a contained change.\033[0m\n' "${TOTAL}"
else
    printf '  %s components moved. For an OS rebuild that is expected and is the\n' "${TOTAL}"
    printf '  point: compare it with the application delta on the same screen.\n'
fi
