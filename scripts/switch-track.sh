#!/usr/bin/bash
# Switch which index the remediated build resolves against.
#
#   ./scripts/switch-track.sh b            # lab mirror  (default while waiting)
#   ./scripts/switch-track.sh a            # real Lightwell Remediated index
#   ./scripts/switch-track.sh vulnerable   # back to plain PyPI, for Acts 0-2
#   ./scripts/switch-track.sh status       # which is configured now
#
# Only two files differ between the tracks: images/app/pip.conf and
# images/app/netrc. Both are gitignored, because which index a build resolves
# against is a per-environment decision and the credentials are real.
#
# Nothing else changes. Not the Containerfile, not build-and-push.sh, not the
# tests, not the images, not the VMs. That is the point: Track B was built so
# that swapping it for the real thing is a two-file change, and so that the
# recording can be made now and the one scene that touches Lightwell content
# re-shot later.
#
# Run ./scripts/check-track-a.sh FIRST before switching to a. It answers the
# only question that matters - whether the catalogue actually covers this
# package at this version, and what exactly the version is called.
set -euo pipefail

cd "$(dirname "$0")/.."

TRACK="${1:-status}"
PIPCONF=images/app/pip.conf
NETRC=images/app/netrc

# Track A
A_INDEX="${A_INDEX:-https://packages.redhat.com/lightwell/python/remediated/simple/}"
A_MACHINE="${A_MACHINE:-packages.redhat.com}"

# Track B
B_HOST="${B_HOST:-lightwell.homelab.com}"
B_USER="${B_USER:-demo}"
B_PASS="${B_PASS:-demo}"

case "${TRACK}" in

status)
    echo "== current configuration =="
    if [[ -f "${PIPCONF}" ]]; then
        grep -E '^(index-url|extra-index-url|trusted-host)' "${PIPCONF}" | sed 's/^/  /'
        if grep -q 'packages.redhat.com' "${PIPCONF}"; then
            echo "  -> TRACK A (real Lightwell Remediated index)"
        elif grep -q "${B_HOST}" "${PIPCONF}"; then
            echo "  -> TRACK B (lab mirror)"
        else
            echo "  -> VULNERABLE (plain PyPI)"
        fi
    else
        echo "  no ${PIPCONF} - build-and-push.sh will refuse to run"
    fi
    echo
    echo "== requirements.txt pin =="
    grep -n '^jinja2' requirements.txt | sed 's/^/  /'
    echo
    echo "== netrc =="
    # Never print the file. The machine line is enough to tell the tracks apart.
    [[ -f "${NETRC}" ]] && grep -o 'machine [^ ]*' "${NETRC}" | sed 's/^/  /' \
                        || echo "  no ${NETRC}"
    exit 0
    ;;

a|A|track-a)
    cat > "${PIPCONF}" <<EOF
# TRACK A - the real Lightwell Remediated index.
#
# No trusted-host: this is a real certificate. If pip complains about TLS here,
# something is wrong and suppressing it is the wrong fix.
[global]
index-url = ${A_INDEX}
extra-index-url = https://pypi.org/simple/
EOF
    if [[ -f "${NETRC}" ]] && grep -q "${A_MACHINE}" "${NETRC}"; then
        echo "  ${NETRC} already has a ${A_MACHINE} entry - left untouched"
    else
        cat > "${NETRC}" <<EOF
# TRACK A credentials. Registry Service Account from access.redhat.com.
# The login is of the form XXXXXXX|service-account-name.
#
# REPLACE THE PLACEHOLDERS BELOW. This file is gitignored and is mounted as a
# build secret, never copied into a layer - but it is still a real token, so
# treat it like one.
machine ${A_MACHINE} login CHANGEME|CHANGEME password CHANGEME
EOF
        chmod 600 "${NETRC}"
        echo "  wrote a ${NETRC} TEMPLATE - edit it before building"
    fi
    echo
    echo "Switched to TRACK A."
    echo
    echo "Then set the pin to whatever check-track-a.sh reported the real index"
    echo "publishes - it may not be +rhlw00001:"
    echo "  sed -i 's/^jinja2==.*/jinja2==<exact version>/' requirements.txt"
    echo
    echo "You can now stop the lab mirror:"
    echo "  sudo podman pod rm -f lightwell"
    ;;

b|B|track-b)
    cat > "${PIPCONF}" <<EOF
# TRACK B - the lab mirror. A genuine backport with local provenance.
#
# trusted-host is required because the mirror's certificate is self-signed.
# That reads identically to how you would configure any corporate mirror.
[global]
index-url = https://${B_HOST}/simple/
extra-index-url = https://pypi.org/simple/
trusted-host = ${B_HOST}
EOF
    printf 'machine %s login %s password %s\n' "${B_HOST}" "${B_USER}" "${B_PASS}" > "${NETRC}"
    chmod 600 "${NETRC}"
    echo "Switched to TRACK B (lab mirror at ${B_HOST})."
    echo
    echo "Make sure the index is actually up - the pod has no restart policy:"
    echo "  sudo podman pod ps --filter name=lightwell"
    echo "  sudo ./scripts/serve-lightwell-mirror.sh"
    ;;

vulnerable|v)
    cat > "${PIPCONF}" <<'EOF'
# VULNERABLE build (Acts 0-2): plain PyPI, no Lightwell index.
[global]
index-url = https://pypi.org/simple/
EOF
    printf '# No credentials needed for PyPI. Placeholder so the build does not refuse.\n' > "${NETRC}"
    chmod 600 "${NETRC}"
    sed -i 's/^jinja2==.*/jinja2==2.11.3/' requirements.txt
    echo "Switched to the VULNERABLE configuration, and reset the pin to 2.11.3."
    ;;

*)
    echo "Usage: $0 {a|b|vulnerable|status}" >&2
    exit 2
    ;;
esac

echo
echo "== resulting state =="
grep -E '^(index-url|extra-index-url|trusted-host)' "${PIPCONF}" | sed 's/^/  /'
grep -n '^jinja2' requirements.txt | sed 's/^/  /'
echo
echo "Rebuild to apply:"
echo "  sudo NS=quay.io/rhte2023 VER=<next> BASE_TAG=10.2 BUILD_DB=no ./scripts/build-and-push.sh"
