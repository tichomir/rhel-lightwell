#!/usr/bin/bash
# Track B: serve the backported wheel from a PEP 503 index, over TLS.
#
#   sudo ./scripts/serve-lightwell-mirror.sh
#   TLS=no sudo ./scripts/serve-lightwell-mirror.sh    # plain HTTP on :8080
#
# Runs under systemd via Quadlet, so it survives a reboot of the builder. That
# matters more than it sounds: a stopped index makes the remediation act fail
# inside the image build with what looks like a missing package.
#
# TLS is the default on purpose. The index URL is on screen during the
# remediation act, and `https://lightwell.homelab.com/simple/` reads as a real
# index where `http://lightwell.homelab.com:8080/simple/` reads as a lab.
#
# Which is exactly why the integrity rule matters (proposal 6.3): this thing is
# indistinguishable from the real Remediated index on camera. Never show a
# packages.redhat.com URL while resolving from here, and caption the scene
# unambiguously if you film it against this rather than against Track A.
#
# Structure: a pod so both containers share localhost.
#
#   nginx        :443  self-signed cert for lightwell.homelab.com
#     -> pypiserver  :8080  on the pod's loopback, not exposed
#
# pypiserver has no TLS of its own, hence the proxy. The certificate is
# self-signed, so pip needs `trusted-host = lightwell.homelab.com` in pip.conf -
# which is how the real index's own docs tell you to handle a corporate mirror
# anyway, so it does not look out of place.
set -euo pipefail

PKGDIR="${PKGDIR:-/srv/lightwell-mirror/packages}"
CERTDIR="${CERTDIR:-/srv/lightwell-mirror/tls}"
POD="${POD:-lightwell}"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-lightwell.homelab.com}"
TLS="${TLS:-yes}"
USER_NAME="${USER_NAME:-demo}"
USER_PASS="${USER_PASS:-demo}"

mkdir -p "${PKGDIR}" "${CERTDIR}"

if ! command -v htpasswd >/dev/null 2>&1; then
    echo "== installing httpd-tools for htpasswd =="
    dnf -y install httpd-tools >/dev/null
fi

HTPASSWD="${CERTDIR}/.htpasswd"
htpasswd -bc "${HTPASSWD}" "${USER_NAME}" "${USER_PASS}" 2>/dev/null
chmod 0644 "${HTPASSWD}"

echo "== packages to serve =="
ls -1 "${PKGDIR}" || { echo "Nothing in ${PKGDIR}. Run make-lightwell-wheel.sh first." >&2; exit 1; }

# Clean slate. Recording means running this repeatedly.
podman pod rm -f "${POD}" >/dev/null 2>&1 || true

if [[ "${TLS}" != "yes" ]]; then
    echo "== plain HTTP on :8080 (TLS=no) =="
    podman run -d --name "${POD}-pypi" -p 8080:8080 \
        -v "${PKGDIR}:/data/packages:Z" \
        -v "${HTPASSWD}:/data/.htpasswd:ro,Z" \
        docker.io/pypiserver/pypiserver:latest \
        run -P /data/.htpasswd -a update /data/packages >/dev/null
    echo
    echo "  index-url = http://${HOSTNAME_FQDN}:8080/simple/"
    exit 0
fi

# Self-signed, with the FQDN in a SAN. Without the SAN, anything that verifies
# properly rejects it outright rather than merely warning.
if [[ ! -f "${CERTDIR}/tls.crt" ]]; then
    echo "== generating a self-signed certificate for ${HOSTNAME_FQDN} =="
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${CERTDIR}/tls.key" -out "${CERTDIR}/tls.crt" \
        -subj "/CN=${HOSTNAME_FQDN}/O=Lightwell Lab Mirror" \
        -addext "subjectAltName=DNS:${HOSTNAME_FQDN},DNS:lightwell" 2>/dev/null
    chmod 0644 "${CERTDIR}/tls.crt"; chmod 0640 "${CERTDIR}/tls.key"
fi

cat > "${CERTDIR}/nginx.conf" <<'NGINX'
events {}
http {
    access_log /dev/stdout;
    server {
        listen 443 ssl;
        ssl_certificate     /tls/tls.crt;
        ssl_certificate_key /tls/tls.key;

        # pip sends the wheel in one request and expects it back whole.
        client_max_body_size 256m;

        location / {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host              $host;
            proxy_set_header X-Forwarded-For   $remote_addr;
            # pypiserver builds absolute URLs from this, so without it the
            # index hands pip http:// links and pip follows them to a closed
            # port. The failure looks like a missing package, not a proxy bug.
            proxy_set_header X-Forwarded-Proto https;
        }
    }
}
NGINX

# Managed by systemd via Quadlet, NOT by a bare `podman run`.
#
# A `podman run -d` container has restart=no and no unit, so it does not come
# back after a reboot. The builder then looks fine and the remediation act
# fails inside the image build with a pip resolution error - which reads as
# "the package is missing" rather than "the index is not running". That is a
# genuinely expensive five minutes to debug mid-session.
#
# Quadlet is the supported way to do this on RHEL 9 with podman 5
# (`podman generate systemd` is deprecated). systemd owns the lifecycle, the
# units are enabled at boot, and a crashed container is restarted.
QUADLET_DIR="${QUADLET_DIR:-/etc/containers/systemd}"
mkdir -p "${QUADLET_DIR}"

cat > "${QUADLET_DIR}/${POD}.pod" <<EOF
[Unit]
Description=Lightwell lab index (pod)

[Pod]
PublishPort=443:443

[Install]
WantedBy=multi-user.target
EOF

cat > "${QUADLET_DIR}/${POD}-pypi.container" <<EOF
[Unit]
Description=pypiserver serving the Lightwell lab index

[Container]
Image=docker.io/pypiserver/pypiserver:latest
Pod=${POD}.pod
Volume=${PKGDIR}:/data/packages:Z
Volume=${HTPASSWD}:/data/.htpasswd:ro,Z
Exec=run -P /data/.htpasswd -a update /data/packages

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > "${QUADLET_DIR}/${POD}-tls.container" <<EOF
[Unit]
Description=TLS front end for the Lightwell lab index

[Container]
Image=docker.io/library/nginx:alpine
Pod=${POD}.pod
Volume=${CERTDIR}:/tls:ro,Z
Volume=${CERTDIR}/nginx.conf:/etc/nginx/nginx.conf:ro,Z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "== wrote Quadlet units to ${QUADLET_DIR} =="
ls -1 "${QUADLET_DIR}"/${POD}* | sed 's/^/  /'

systemctl daemon-reload

# Quadlet turns lightwell.pod into lightwell-pod.service. Starting that pulls
# in both containers; enabling it is what makes this survive a reboot.
echo "== starting ${POD}-pod.service =="
systemctl enable --now "${POD}-pod.service" 2>/dev/null || systemctl start "${POD}-pod.service"

for _ in $(seq 1 20); do
    curl -sk -o /dev/null -m 3 "https://${HOSTNAME_FQDN}/simple/" && break
    sleep 2
done

systemctl --no-pager --plain is-enabled "${POD}-pod.service" 2>/dev/null \
    | sed 's/^/  pod service enabled: /'
podman pod ps --filter name="${POD}"

cat <<NEXT

== verify ==
  curl -sk https://${HOSTNAME_FQDN}/simple/jinja2/ | grep -o 'rhlw[^"<]*'

== pip configuration for the remediated build ==
  images/app/pip.conf:
    [global]
    index-url = https://${HOSTNAME_FQDN}/simple/
    extra-index-url = https://pypi.org/simple/
    trusted-host = ${HOSTNAME_FQDN}

  images/app/netrc:
    machine ${HOSTNAME_FQDN} login ${USER_NAME} password ${USER_PASS}

The certificate is self-signed, so trusted-host is required. Note that reads
identically to how you would configure any corporate mirror, which is part of
why this is convincing on camera - and part of why the integrity rule matters.
NEXT
