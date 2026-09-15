#!/usr/bin/bash
# The coverage gap, on one host, in one screen.
#
# Run ON im-train:
#   ssh im-train 'sudo bash -s' < scripts/show-coverage-gap.sh
#
# WHY THIS SCENE EXISTS
#
# The hardest thing to land in this demo is that a fully patched, fully
# compliant RHEL host can still be carrying a reachable vulnerability - and
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
dim "  The obvious question. Two honest answers, and one that sounds good but"
dim "  is circular - see the note at the end."
echo
printf '  1. '; echo "It IS 3.1.6. Using it is the 3.1.x migration - contextfunction"
printf '     '; echo "removed, Markup moved to markupsafe, autoescape defaults changed."
printf '     '; echo "Same code change, same regression cycle, same change board."
printf '     '; echo "This is the whole reason the demo exists."
echo
printf '  2. '; echo "It covers a minority of the dependency set. The five direct pins"
printf '     '; echo "in requirements.txt, against what RHEL 10 actually ships:"
echo
# NOTE: rpm -q on THIS host only says "installed", not "an RPM exists" - an
# image-mode guest has no dnf repos at all. Availability below was checked
# against RHEL 10 BaseOS + AppStream inside a repo-enabled container.
have=0; miss=0
for entry in "jinja2:yes:3.1.6" "markupsafe:yes:2.1.3" "fastapi:no:-" "uvicorn:no:-" "psycopg:no:see note"; do
    p="${entry%%:*}"; rest="${entry#*:}"; avail="${rest%%:*}"; ver="${rest#*:}"
    if [[ "${avail}" == "yes" ]]; then
        printf '       %-14s RPM exists      %s\n' "${p}" "${ver}"
        have=$((have+1))
    else
        printf '       %-14s no RPM          %s\n' "${p}" "${ver}"
        miss=$((miss+1))
    fi
done
echo
printf '     '; echo "So ${have} of 5 covered, ${miss} of 5 not. And the transitive tree - starlette,"
printf '     '; echo "pydantic, anyio, h11 - has no RPMs either."
echo
printf '     '; echo "Note on psycopg: RHEL ships python3-psycopg2 (2.9.9). That is a"
printf '     '; echo "DIFFERENT package with a different API, not the psycopg 3 this app"
printf '     '; echo "uses. Do not claim there is no Postgres driver; say there is no"
printf '     '; echo "psycopg 3, which is the one in requirements.txt."
echo
printf '  3. '; echo "Mixing the two sources is worse than either. Half the dependency"
printf '     '; echo "tree pinned in requirements.txt and half tracking the RHEL minor"
printf '     '; echo "release is the worst of both. The venv exists to prevent exactly that."
echo
dim "  WHAT NOT TO SAY: \"the OS markupsafe is 2.1.3 but this app needs 2.0.1\"."
dim "  True, but circular - the 2.0.1 pin exists ONLY because jinja2 is pinned at"
dim "  2.11. Take the OS jinja2 3.1.6 and OS markupsafe 2.1.3 works fine with it."
dim "  It is not an argument against using the OS copy."
echo

bold "== what the platform reports about itself =="
printf '  OS version      '; . /etc/os-release && echo "${VERSION_ID}"
printf '  bootc image     '; bootc status --json 2>/dev/null | jq -r '.status.booted.image.image.image // "n/a"'
printf '  pending updates '; (dnf -q check-update >/dev/null 2>&1 && echo "none") || echo "n/a (image mode: /usr is read-only, dnf is not how this host is patched)"
echo
dim "  Nothing above is wrong or out of date. That is the entire point: the host"
dim "  is correct, and the application still carries a reachable vulnerability."
echo
dim "  BE PRECISE IF ASKED \"can you pop an alert?\". In THIS app, no - the UI"
dim "  escapes on output, so the filter's result never reaches an HTML context"
dim "  unescaped. The library flaw is real and reachable from a request; whether"
dim "  it becomes XSS depends on the consumer's output path. xmlattr exists to"
dim "  produce markup for insertion, so an app that uses it as intended is"
dim "  exposed. Saying that is stronger than overclaiming and being corrected."
