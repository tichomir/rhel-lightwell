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
    print(f"  jinja2 {__version__:<20} SAFE        refuses to render - {type(exc).__name__}: {exc}")
    sys.exit(0)
if key in out:
    print(f"  jinja2 {__version__:<20} VULNERABLE  emits it anyway - {out!r}")
else:
    print(f"  jinja2 {__version__:<20} SAFE        sanitised - {out!r}")
PY
}

# This scene only works from the VULNERABLE baseline. Run it after the
# remediation act and both interpreters report SAFE - which is correct, and
# destroys the contrast the scene exists to show. Better to say so loudly than
# to let it look like the probe is broken.
APP_JINJA=$("${APP_PY}" -c 'import jinja2; print(jinja2.__version__)' 2>/dev/null)
if [[ "${APP_JINJA}" == *rhlw* ]]; then
    printf '\033[1;33m'
    cat <<WARN
== WRONG STATE FOR THIS SCENE ==

  The application is already remediated (jinja2 ${APP_JINJA}), so both copies
  will report SAFE below. That is correct behaviour and useless on camera:
  this scene is the Act 2 contrast between a patched OS copy and an
  unpatched application copy.

  Revert to a vulnerable baseline first:
    VIRSH_URI=qemu+ssh://<user>@<hypervisor>/system SNAP=act1-done ./scripts/reset.sh

  Continuing anyway, for reference.

WARN
    printf '\033[0m'
fi

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

dim "  SAFE here means the patched library REFUSES to render rather than"
dim "  emitting markup a browser will misparse. A space is illegal in an HTML"
dim "  attribute name: a browser ends the name at the space and treats the rest"
dim "  as a SEPARATE attribute - which is how an attacker gets to inject one."
dim "  Failing closed is the fix."
echo

bold "== \"so why not just use the OS copy?\" =="
dim "  The obvious question, and the answer is the whole demo:"
echo
printf '  1. '; echo "It IS 3.1.6. Using it is the 3.1.x migration - contextfunction"
printf '     '; echo "removed, Markup moved to markupsafe, autoescape defaults changed."
printf '     '; echo "Same code change, same regression cycle, same change board."
echo
printf '  2. '; echo "The OS markupsafe is $(rpm -q --qf '%{VERSION}' python3-markupsafe 2>/dev/null); this app needs 2.0.1. Jinja2 2.11"
printf '     '; echo "imports soft_unicode, which markupsafe 2.1 removed."
echo
printf '  3. '; echo "It only helps for jinja2. RHEL ships no RPM at all for the rest:"
for p in fastapi uvicorn starlette psycopg pydantic; do
    printf '       python3-%-12s ' "${p}"
    rpm -q "python3-${p}" >/dev/null 2>&1 && echo "present" || echo "no such package"
done
printf '     '; echo "Four of five runtime dependencies have no OS packaging to fall back to."
echo
printf '  4. '; echo "The venv exists so the dependencies are pinned and reproducible."
printf '     '; echo "Tracking whatever the OS happens to ship makes the application's"
printf '     '; echo "behaviour a function of the RHEL minor release."
echo
dim "  So the boundary is not something you can opt out of by being clever."
echo

bold "== what the platform reports about itself =="
printf '  OS version      '; . /etc/os-release && echo "${VERSION_ID}"
printf '  bootc image     '; bootc status --json 2>/dev/null | jq -r '.status.booted.image.image.image // "n/a"'
printf '  pending updates '; (dnf -q check-update >/dev/null 2>&1 && echo "none") || echo "n/a (image mode: /usr is read-only, dnf is not how this host is patched)"
echo
dim "  Nothing above is wrong or out of date. That is the entire point: the host"
dim "  is correct, and the application is still exploitable."
