#!/usr/bin/bash
# Step 1 of the build. Run this before writing or building anything else.
#
# Two questions, both of which can sink the chosen dependency:
#
#   (a) Does the pinned version install AND WORK on RHEL 10's Python 3.12?
#       Installing is not enough. Jinja2 2.11's asyncsupport module uses
#       asyncio.coroutine, which was REMOVED in Python 3.11. If that is reached
#       at import time the pin is dead, and pip will not tell you - only an
#       actual import and render will.
#
#   (b) Does the upstream fix cherry-pick cleanly onto the pinned version?
#       This decides whether the Track B backport takes ten minutes or an hour.
#
# Exit non-zero means change candidate. See the build guide, section 2.2.
set -uo pipefail

PKG="${PKG:-jinja2}"
VER="${VER:-2.11.3}"
EXTRA="${EXTRA:-markupsafe==2.0.1}"
VENV="$(mktemp -d)/pincheck"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

bold "== (a) install and exercise ${PKG}==${VER} on $(python3 -V 2>&1) =="

python3 -m venv "${VENV}" || { red "FAIL: cannot create venv"; exit 1; }
# shellcheck disable=SC1091
source "${VENV}/bin/activate"

python3 -m pip install --quiet --upgrade pip
if ! python3 -m pip install --quiet "${PKG}==${VER}" ${EXTRA}; then
    red "FAIL: ${PKG}==${VER} does not install on this Python."
    red "      Change candidate - see build guide section 2.2."
    exit 1
fi
green "  install: ok"

# The check that actually matters: import and render.
python3 - <<'PYCHECK'
import sys

try:
    import jinja2
    from jinja2 import StrictUndefined
    from jinja2.sandbox import SandboxedEnvironment
except Exception as exc:
    print(f"  import: FAIL - {type(exc).__name__}: {exc}")
    sys.exit(1)
print(f"  import: ok (jinja2 {jinja2.__version__})")

try:
    env = SandboxedEnvironment(autoescape=False, undefined=StrictUndefined)
    out = env.from_string("{{ a }}-{{ b|upper }}").render(a=1, b="ok")
    assert out == "1-OK", out
except Exception as exc:
    print(f"  render: FAIL - {type(exc).__name__}: {exc}")
    sys.exit(1)
print("  render: ok")

# The filter the CVE observable depends on must exist and be reachable.
try:
    env = SandboxedEnvironment(autoescape=False)
    rendered = env.from_string("{{ d|xmlattr }}").render(d={"data-x y": "1"})
except Exception as exc:
    print(f"  xmlattr: rejected at render - {type(exc).__name__}")
    print("  NOTE: this version appears to already carry the fix. For Act 2 you")
    print("        need a version that emits it. Check the pin.")
    sys.exit(0)

if "data-x y" in rendered:
    print("  xmlattr: emits the unsafe name -> suitable for Act 2 (vulnerable)")
else:
    print("  xmlattr: filters the unsafe name -> already remediated")
PYCHECK
CHECK=$?
deactivate
[[ ${CHECK} -ne 0 ]] && { red "FAIL: installed but not usable. Change candidate."; exit 1; }

bold ""
bold "== (b) does the upstream fix cherry-pick cleanly? =="
cat <<'NOTE'
  Not automated: the commit differs per CVE and you must read the advisory.

    git clone https://github.com/pallets/jinja.git /tmp/jinja
    cd /tmp/jinja
    git checkout -b lwtest 2.11.3
    git cherry-pick <fix commit from the GHSA advisory>
    git diff 2.11.3 --stat

  Want: one file, a handful of lines, no conflicts. If you end up resolving
  conflicts across three files, change candidate rather than compromise. A
  half-backport is worse than no demo.
NOTE

green ""
green "Pin check (a) passed. Complete (b) by hand, then lock the dependency."
