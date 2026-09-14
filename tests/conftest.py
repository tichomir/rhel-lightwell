"""Shared pytest configuration.

The --expect flag lets the same CVE test file assert the correct thing in both
states, so Act 2 and Act 4 both show a green suite. A red suite on camera reads
as a broken demo even when red is the correct result.
"""
import pytest


def pytest_addoption(parser):
    parser.addoption(
        "--expect",
        action="store",
        default="auto",
        choices=["auto", "vulnerable", "remediated"],
        help=(
            "Which state the installed dependency is expected to be in. "
            "'auto' infers it from the installed version string."
        ),
    )


@pytest.fixture(scope="session")
def expected_state(pytestconfig):
    choice = pytestconfig.getoption("--expect")
    if choice != "auto":
        return choice

    from app.sysinfo import lightwell_state

    return "remediated" if lightwell_state()["remediated"] else "vulnerable"
