#!/usr/bin/bash
# What "exploitable" actually means here - the Act 2 escalation.
#
# Run ON im-train:
#   ssh im-train 'sudo bash -s' < scripts/show-injection.sh
#
# WHAT THIS ADDS, AND WHY IT IS NOT AN EXPLOIT
#
# show-coverage-gap.sh proves the unsafe attribute NAME survives into the
# rendered output. On its own that is abstract - an audience sees a string and
# has to take your word that it matters.
#
# This scene closes that gap by showing an HTML parser reading the same string
# and reporting an attribute the template author never wrote. That is the whole
# security claim, made concrete:
#
#   author wrote:     one attribute
#   parser reports:   two, the second one attacker-chosen
#
# It stops deliberately short of a working exploit. No event handler, no script,
# no alert box. Three reasons, and none is squeamishness:
#
#   1. A recording gets forwarded and re-shown without you in the room. A
#      functioning XSS inside it is a liability that outlives the demo.
#   2. A benign demonstration re-runs identically on every take. A payload
#      depends on a browser, a page and a user action, none of which are
#      deterministic on camera.
#   3. The claim being made is "untrusted input reaches a context it must not",
#      and an attribute the developer never wrote IS that claim. An alert box
#      adds theatre, not evidence.
#
# The honest escalation to state out loud: the second attribute here is
# data-injected, which does nothing. Substituting an event-handler attribute is
# what turns this into stored XSS, and that is a one-word change an attacker
# makes and you do not have to demonstrate.
#
# AND SAY THIS TOO: the same grype report carries CVE-2024-56326 at CVSS 7.8 -
# a sandbox escape, and the most serious of the four. It is NOT what is shown
# here, and deliberately so: a working sandbox escape is a payload, and this
# scene exists to avoid putting one in a recording. The backport fixes it and
# tests/test_sandbox_cve.py proves that with upstream's own proof of concept -
# so the place to demonstrate it is the test suite, not the screen.
#
# Saying that distinction out loud is more honest and sounds more competent
# than implying this attribute injection is the whole story.
set -uo pipefail

APP_PY="${APP_PY:-/opt/app/venv/bin/python}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# The attacker controls the attribute NAME. Values are escaped by xmlattr;
# names were not, which is the bug.
INTENDED_KEY="data-track-id"
UNSAFE_KEY="data-track data-injected"

"${APP_PY}" - "${INTENDED_KEY}" "${UNSAFE_KEY}" <<'PY'
import sys
from html.parser import HTMLParser
from jinja2 import Environment, __version__

intended_key, unsafe_key = sys.argv[1], sys.argv[2]
env = Environment()

def render(key):
    try:
        return env.from_string("{{ d|xmlattr }}").render(d={key: "1"}), None
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"

class Attrs(HTMLParser):
    found = []
    def handle_starttag(self, tag, attrs):
        Attrs.found = attrs

def parse(fragment):
    Attrs.found = []
    Attrs().feed(f"<div{fragment}>ticket</div>")
    return Attrs.found

BOLD, DIM, RED, GREEN, OFF = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[0m"
print(f"  jinja2 in the application venv: {__version__}")

print(f"\n{BOLD}  1. what the template author wrote{OFF}")
out, _ = render(intended_key)
print(f"     key        {intended_key!r}")
print(f"     rendered  {out!r}")
for k, v in parse(out):
    print(f"     parsed     {k!r} = {v!r}")
print(f"{DIM}     One attribute. Exactly what was intended.{OFF}")

print(f"\n{BOLD}  2. what an attacker-supplied key produces{OFF}")
out, err = render(unsafe_key)
print(f"     key        {unsafe_key!r}")
if err:
    print(f"     {GREEN}rejected   {err}{OFF}")
    print(f"{DIM}     This jinja2 refuses to render it. Nothing to show - which means{OFF}")
    print(f"{DIM}     you are on a remediated build. Revert to a vulnerable baseline.{OFF}")
    sys.exit(0)

print(f"     rendered  {out!r}")
attrs = parse(out)
for k, v in attrs:
    marker = f"  {RED}<-- the author never wrote this{OFF}" if k == "data-injected" else ""
    print(f"     parsed     {k!r} = {v!r}{marker}")

print(f"\n{BOLD}  3. the point{OFF}")
print(f"     author wrote    1 attribute")
print(f"     parser reports  {len(attrs)} attributes")
if any(k == "data-injected" for k, _ in attrs):
    print(f"\n{RED}     An attribute chosen by whoever supplied that key is now part of{OFF}")
    print(f"{RED}     the markup. That is the vulnerability, in full.{OFF}")
PY

bold "where this stops, on purpose"
dim "  The injected attribute above is data-injected. It does nothing."
dim "  Substituting an event-handler attribute is what makes this stored XSS -"
dim "  a one-word change for an attacker, and one you do not need to perform to"
dim "  have proved the point."
echo
dim "  There is no working exploit in this repository or in the recording. A"
dim "  recording gets forwarded and re-shown without you in the room."
echo
dim "  And note what this does NOT claim: that this app can be made to pop an"
dim "  alert. It cannot - the UI escapes on output. What is demonstrated is that"
dim "  the LIBRARY hands its caller markup a parser misreads. xmlattr exists to"
dim "  produce attributes for insertion into HTML, so a consumer using it as"
dim "  intended is exposed; this app is not, because it escapes. Defence in"
dim "  depth saved it, and relying on that is not a patching strategy."
echo
dim "  And CVE-2024-56326 in the same grype report is a SANDBOX ESCAPE at CVSS"
dim "  7.8 - the most serious of the four, and arbitrary code execution rather"
dim "  than attribute injection. It is deliberately NOT demonstrated here: a"
dim "  working sandbox escape is a payload, and this scene exists to avoid"
dim "  putting one in a recording."
echo
dim "  It IS fixed by the backport, and proved in tests/test_sandbox_cve.py"
dim "  using the proof-of-concept template from upstream's own fix commit. On"
dim "  unpatched 2.11.3 that template renders the __import__ builtin. The right"
dim "  place to show that is the test run, not the screen."
