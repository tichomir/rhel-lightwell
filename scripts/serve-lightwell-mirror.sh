#!/usr/bin/bash
# Track B: serve the backported wheel from a PEP 503 simple index.
#
# On camera this is indistinguishable from a real index, which is exactly why
# the integrity rule in the proposal matters: never show a packages.redhat.com
# URL while resolving from here.
set -euo pipefail

PKGDIR="${PKGDIR:-/srv/lightwell-mirror/packages}"
PORT="${PORT:-8080}"
NAME="${NAME:-lightwell-mirror}"
USER_NAME="${USER_NAME:-demo}"
USER_PASS="${USER_PASS:-demo}"

mkdir -p "${PKGDIR}"

if ! command -v htpasswd >/dev/null 2>&1; then
    echo "Installing httpd-tools for htpasswd"
    dnf -y install httpd-tools
fi

HTPASSWD="${PKGDIR}/../.htpasswd"
htpasswd -bc "${HTPASSWD}" "${USER_NAME}" "${USER_PASS}"

podman rm -f "${NAME}" >/dev/null 2>&1 || true
podman run -d --name "${NAME}" \
    -p "${PORT}:8080" \
    -v "${PKGDIR}:/data/packages:Z" \
    -v "${HTPASSWD}:/data/.htpasswd:ro,Z" \
    docker.io/pypiserver/pypiserver:latest \
    run -P /data/.htpasswd -a update,download,list /data/packages

echo
echo "Serving ${PKGDIR} on port ${PORT}"
echo
echo "Add to ~/.netrc on the builder:"
echo "  machine lightwell.rh-lab.labs login ${USER_NAME} password ${USER_PASS}"
echo
echo "Then:"
echo "  pip config set global.index-url https://lightwell.rh-lab.labs/simple/"
echo "  pip config set global.extra-index-url https://pypi.org/simple/"
echo
echo "Verify:"
echo "  pip index versions jinja2"
