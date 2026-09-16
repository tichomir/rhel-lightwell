"""The two sandbox escapes, using upstream's own proof-of-concept templates.

WHAT THIS TESTS
---------------
The application renders operator-supplied receipt templates, so it uses
jinja2's SandboxedEnvironment - see app/receipts.py. That makes the sandbox a
security boundary here rather than an unused feature, and these two CVEs are
failures of that boundary:

  CVE-2024-56326  a str.format method obtained indirectly is not sandboxed,
                  so a template can reach __import__.  Fixed upstream in 3.1.5.
  CVE-2025-27516  the attr filter used a raw getattr, so |attr("format")
                  returns an unsandboxed method.       Fixed upstream in 3.1.6.

WHY THESE ARE THE SERIOUS ONES
------------------------------
The xmlattr CVEs in tests/test_cve.py are attribute injection - bad, but
bounded by what the consumer does with the markup. These two are arbitrary
code execution from a template. CVE-2024-56326 is CVSS 7.8, the highest in the
set, and on unpatched 2.11.3 the template below renders

    <built-in function __import__>

which is one step from an import of os.

WHY THE POCs ARE COPIED VERBATIM
--------------------------------
Both templates are taken unchanged from the upstream fix commits - 48b0687e
and 90457bbf, in tests/test_security.py. Writing our own would invite the
question of whether we had picked something easy. These are the exact cases
upstream considers proof, and they are safe to run: reaching __import__ is
where they stop. Nothing is imported and nothing is executed.

A NOTE ON CVE-2025-27516 IN THE VULNERABLE STATE
------------------------------------------------
Unpatched 2.11.3 already blocks the attr-filter PoC, because 2.11.3 sandboxes
str.format at call time and that hook catches it. The vulnerability is really a
regression introduced by the 3.1.5 fix, which moved sandboxing to access time
and left do_attr behind. osv.dev records the range as "introduced: 0", which is
over-broad for 2.11.x.

So this test asserts "blocked" in BOTH states, and that is the point worth
knowing: our backport must not regress it. Applying the sandbox half of
patches/0002 without the do_attr half would introduce this CVE into 2.11.3.
"""
import pytest

from jinja2.exceptions import SecurityError
from jinja2.sandbox import SandboxedEnvironment


def _escaped(render):
    """True if the sandbox was escaped - i.e. the payload rendered."""
    try:
        render()
    except SecurityError:
        return False
    except Exception as exc:  # noqa: BLE001
        # Anything else is neither a clean block nor a clean escape. Fail loudly
        # rather than quietly counting it as remediated.
        pytest.fail(f"unexpected {type(exc).__name__}: {exc}")
    return True


def _indirect_str_format():
    """CVE-2024-56326, verbatim from upstream commit 48b0687e."""

    def run(value, arg):
        return value.run(arg)

    env = SandboxedEnvironment()
    env.filters["run"] = run
    return env.from_string(
        """{% set
            ns = namespace(run="{0.__call__.__builtins__[__import__]}".format)
        %}
        {{ ns | run(not_here) }}
        """
    ).render


def _attr_filter_format():
    """CVE-2025-27516, verbatim from upstream commit 90457bbf."""
    env = SandboxedEnvironment()
    return env.from_string(
        """{{ "{0.__call__.__builtins__[__import__]}"
              | attr("format")(not_here) }}"""
    ).render


def test_indirect_str_format_matches_expected_state(expected_state):
    """CVE-2024-56326 - escapes on 2.11.3, must be blocked after remediation."""
    escaped = _escaped(_indirect_str_format())

    if expected_state == "vulnerable":
        assert escaped, (
            "Expected the vulnerable behaviour but the sandbox held. The "
            "installed jinja2 may already carry the fix - check `pip show "
            "jinja2` against requirements.txt."
        )
    else:
        assert not escaped, (
            "The sandbox was escaped after remediation. patches/0002 is either "
            "not applied or not applied completely - check that the wheel "
            "version contains 'rhlw'."
        )


def test_attr_filter_is_blocked_in_both_states():
    """CVE-2025-27516 - blocked before AND after, and that is deliberate.

    See the module docstring: 2.11.3's call-time hook already stops this, so
    the job of the backport is not to fix it but to avoid breaking it while
    fixing CVE-2024-56326.
    """
    assert not _escaped(_attr_filter_format()), (
        "The attr filter escaped the sandbox. If this fails in the remediated "
        "state, the sandbox half of patches/0002 was applied without the "
        "do_attr half - that combination INTRODUCES CVE-2025-27516."
    )


def test_sandbox_still_works_normally():
    """The control. A sandboxed template must still render ordinary data.

    If this fails, the backport broke the sandbox rather than hardening it, and
    the remediation claim is worthless.
    """
    env = SandboxedEnvironment()
    out = env.from_string("{{ name }} has {{ items|length }} items").render(
        name="IMT-4100", items=[1, 2, 3]
    )
    assert out == "IMT-4100 has 3 items"


def test_str_format_still_works_in_sandbox():
    """str.format must keep working for legitimate use.

    patches/0002 wraps the method rather than forbidding it, so this must still
    render - and it is the single most likely thing to regress.
    """
    env = SandboxedEnvironment()
    out = env.from_string('{{ "{} to {}".format(a, b) }}').render(
        a="Brussels", b="Paris"
    )
    assert out == "Brussels to Paris"
