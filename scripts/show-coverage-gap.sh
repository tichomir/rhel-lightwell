#!/usr/bin/bash
# The coverage gap, on one host, in one screen.
#
# Run ON im-train:
#   ssh im-train 'sudo bash -s' < scripts/show-coverage-gap.sh
#
# WHY THIS SCENE EXISTS
#
# The hardest thing to land in this demo is that a fully patched, fully
# compliant RHEL host can still be running an exploitable application - and
# that this is not a failure of RHEL, it is the boundary of what a RHEL
# subscription has ever covered.
#
# Arguing that is slow. This host proves it in five seconds, because it happens
# to carry the SAME library twice:
#
#   /usr/lib/python3.12/.../jinja2   from python3-jinja2, an RPM. Red Hat's.
#                                    Patched. Tracked by the OS lifecycle.
#                                    cloud-init pulled it in, nobody asked for it.
#
#   /opt/app/venv/.../jinja2         from pip, at image build time. Yours.
#                                    Pinned, vulnerable, and outside every
#                                    mechanism the OS provides.
#
# Same CVE. Same filter. Same machine. One is fixed and one is not, and the
# difference is entirely about who is responsible for it.
#
# This is also the honest framing of what Lightwell sells: not "RHEL missed
# something", but "the OS vendor patched the part they ship, and Lightwell
# extends that same discipline to the part you ship".
set -uo pipefail

SYS_PY=/usr/bin/python3
APP_PY=/opt/app/venv/bin/python

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# A key whose NAME contains a space. Illegal in HTML, and enough to terminate
# the attribute name early and inject another attribute. Benign by itself: no
# script, no event handler, no payload.
PROBE='data-track id'

probe_script() {
cat <<'PY'
import sys
from jinja2 import Environment, __version__
key = sys.argv[1]
try:
    out = Environment().from_string("{{ d|xmlattr }}").render(d={key: "1"})
except Exception as exc:
    print(f"  jinja2 {__version__:<20} REJECTED   {type(exc).__name__}: {exc}")
    sys.exit(0)
if key in out:
    print(f"  jinja2 {__version__:<20} EMITTED    {out!r}")
else:
    print(f"  jinja2 {__version__:<20} sanitised  {out!r}")
PY
}

bold "== where this host's two copies of jinja2 come from =="
printf '  OS  '; rpm -q python3-jinja2 2>/dev/null || echo "python3-jinja2 not installed"
printf '  app '; "${APP_PY}" -m pip show jinja2 2>/dev/null \
    | awk '/^Name|^Version/{printf "%s ", $2} END{print "(pip, in /opt/app/venv)"}'
echo
dim "  The OS copy arrived with cloud-init. Nobody chose it, and Red Hat patches it."
dim "  The app copy arrived from requirements.txt at image build time. You chose it,"
dim "  you pinned it, and no OS mechanism has ever touched it."
echo

bold "== the same CVE probe, against both, on this machine =="
dim "  attribute name: '${PROBE}'  (a space is illegal in an HTML attribute name)"
probe_script | "${SYS_PY}" /dev/stdin "${PROBE}"
probe_script | "${APP_PY}" /dev/stdin "${PROBE}"
echo

bold "== what the platform reports about itself =="
printf '  OS version      '; . /etc/os-release && echo "${VERSION_ID}"
printf '  bootc image     '; bootc status --json 2>/dev/null | jq -r '.status.booted.image.image.image // "n/a"'
printf '  pending updates '; (dnf -q check-update >/dev/null 2>&1 && echo "none") || echo "n/a (image mode: /usr is read-only, dnf is not how this host is patched)"
echo
dim "  Nothing above is wrong or out of date. That is the entire point: the host"
dim "  is correct, and the application is still exploitable."
