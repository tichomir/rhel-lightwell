"""The CVE observable: one assertion that flips between Act 2 and Act 4.

WHAT THIS TESTS
---------------
Jinja2's xmlattr filter builds an HTML attribute string from a mapping. An
attribute *name* may not contain whitespace, '/', '>' or '='. A key containing
any of those can close the attribute name early and inject a further attribute
into the rendered markup - the flaw behind CVE-2024-22195 and, for additional
characters, CVE-2024-34064. Both are fixed only in the Jinja2 3.1.x line.

WHY IT LOOKS LIKE THIS
----------------------
The probe key is 'data-track id' - a plain name containing a space. No script,
no event handler, no payload. Three reasons:

  1. A working exploit inside a recording that gets forwarded is a liability.
  2. A benign assertion re-runs identically on every take. A staged shell
     prompt does not.
  3. The security claim being made is 'untrusted input reaches a context it
     must not', and that is exactly what this demonstrates.

The assertion is on *rendered output*, not on a particular exception type, so it
stays correct whether the fixed release raises, filters or escapes. Do not
tighten it to assert ValueError without first confirming the behaviour of the
version you actually installed.

In Act 2 use the grype report to state the real risk - the sandbox escapes in
the same report are the serious ones - and demonstrate only what is safe to put
on screen. Saying that distinction out loud is more honest and sounds more
competent than pretending this XSS is the whole story.
"""
import pytest

from app import receipts

# An attribute name containing a space. Benign on its own; illegal as an HTML
# attribute name, which is the entire point.
UNSAFE_KEY = "data-track id"
SAFE_KEY = "data-track-id"


def _emitted(key, value="1"):
    """True if the key survives verbatim into rendered output."""
    try:
        rendered = receipts.render_attributes({key: value})
    except Exception:  # noqa: BLE001 - rejection is the remediated behaviour
        return False
    return key in rendered


def test_safe_attribute_name_always_renders():
    """A legal attribute name must work in both states.

    This is the control. If it fails, the library is broken rather than fixed,
    and the remediation claim is worthless.
    """
    rendered = receipts.render_attributes({SAFE_KEY: "42"})
    assert SAFE_KEY in rendered
    assert "42" in rendered


def test_unsafe_attribute_name_matches_expected_state(expected_state):
    emitted = _emitted(UNSAFE_KEY)

    if expected_state == "vulnerable":
        assert emitted, (
            "Expected the vulnerable behaviour but the unsafe attribute name was "
            "not emitted. The installed Jinja2 may already carry the fix - check "
            "`pip show jinja2` against requirements.txt."
        )
    else:
        assert not emitted, (
            "Expected the remediated behaviour but the unsafe attribute name was "
            "emitted verbatim. The Lightwell artifact may not be installed - "
            "check that the version string contains 'rhlw'."
        )


def test_probe_endpoint_agrees_with_direct_render(expected_state):
    """The UI probe and the test must never disagree.

    They are shown side by side on camera, so a mismatch would be visible.
    """
    probe = receipts.attribute_probe(key=UNSAFE_KEY)
    assert probe["unsafe_key_emitted"] is _emitted(UNSAFE_KEY)

    if expected_state == "remediated":
        assert probe["unsafe_key_emitted"] is False


@pytest.mark.parametrize("key", ["data-a b", "data-a>b", "data-a=b", "data-a/b"])
def test_other_illegal_name_characters(key, expected_state):
    """Whitespace is one of four characters that can break out of a name.

    Not all four are necessarily covered by the same fix, so this test records
    what the installed version actually does rather than asserting a policy.
    Run with -v in both acts and note the difference; it is useful colour when
    someone asks how complete the backport is.
    """
    emitted = _emitted(key)
    if expected_state == "remediated":
        assert emitted is False, f"{key!r} still emitted after remediation"
