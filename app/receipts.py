"""Receipt rendering. This is the vulnerable surface of the demo.

WHY THIS EXISTS
---------------
An operator supplies a template for printed ticket receipts, and the service
renders it. That is an ordinary enterprise feature, and it is what puts
operator-influenced input in front of a template engine. Nothing here is
contrived for the demo.

The library doing the rendering is Jinja2, pinned in requirements.txt to a
version carrying CVEs whose only upstream fix is the 3.1.x line. Getting there
means Python 2 support dropped, contextfunction removed, Markup relocated to
markupsafe, autoescape defaults changed - a migration, not a version bump. That
is the whole argument for Lightwell.

DELIBERATELY NOT HERE
---------------------
There is no exploit payload in this repository, and none should be added. The
before/after proof is a benign, deterministic assertion about the xmlattr filter
(see tests/test_cve.py). Two reasons: a working exploit in a recording that
gets forwarded is a liability, and a benign assertion re-runs identically on
every take, which a staged shell prompt does not.

SWAPPING THE VULNERABLE DEPENDENCY
----------------------------------
If the Jinja2 pin fails the Python 3.12 check (scripts/pincheck.sh), only two
files need to change: this one and tests/test_cve.py, plus one line in
requirements.txt. Keep the same three public functions and the tests stay valid.
"""
from jinja2 import StrictUndefined
from jinja2.sandbox import SandboxedEnvironment

DEFAULT_TEMPLATE = """IMAGE MODE TRAIN SERVICE
Reference: {{ booking.reference }}
Passenger: {{ booking.passenger_name }}
Service:   {{ booking.service_code }}
Route:     {{ booking.origin_name }} to {{ booking.destination_name }}
Date:      {{ booking.travel_date }} at {{ booking.depart_time }}
Fare:      EUR {{ '%.2f'|format(booking.price_eur) }}
"""


def _environment():
    """A sandboxed environment, as an operator-supplied template requires.

    autoescape stays off because receipts are plain text, not HTML. The xmlattr
    filter is still reachable, which is the point: it is reachable in real
    applications too.
    """
    return SandboxedEnvironment(autoescape=False, undefined=StrictUndefined)


def render_receipt(template_source, booking):
    """Render an operator-supplied receipt template for one booking."""
    template = _environment().from_string(template_source or DEFAULT_TEMPLATE)
    return template.render(booking=booking)


def render_attributes(attributes):
    """Render a dict through the xmlattr filter and return the result.

    This is the observable the demo turns on. The xmlattr filter builds an HTML
    attribute string from a mapping. An attribute *name* may not contain
    whitespace, '/', '>' or '='; a key containing any of those can terminate the
    attribute name early and inject a new attribute into the markup.

    Vulnerable Jinja2 emits such a key verbatim. Fixed Jinja2 (3.1.3 and later)
    rejects it. The test asserts on the rendered output rather than on a
    particular exception type, so it stays correct whichever mechanism the fix
    happens to use.
    """
    template = _environment().from_string("{{ attributes|xmlattr }}")
    return template.render(attributes=attributes)


def attribute_probe(key="data-track id", value="1"):
    """Report whether an unsafe attribute name survives into rendered output.

    Used by the /api/probe endpoint so the state is visible in the UI as well as
    in the test suite. Benign by construction: the key is a name containing a
    space, not an event handler or a script.
    """
    try:
        rendered = render_attributes({key: value})
    except Exception as exc:  # noqa: BLE001 - a rejection is the remediated path
        return {
            "unsafe_key_emitted": False,
            "rendered": None,
            "rejected_with": type(exc).__name__,
            "detail": str(exc),
        }

    return {
        "unsafe_key_emitted": key in rendered,
        "rendered": rendered,
        "rejected_with": None,
        "detail": None,
    }
