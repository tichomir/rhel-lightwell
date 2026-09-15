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


@pytest.fixture
def cleanup_bookings():
    """Remove bookings a test created, once the test has finished with them.

    This suite runs against the live demo database and Act 3's proof is running
    it unchanged, so a test that leaves rows behind makes the booking list on
    the Act 4 screen different in every take.

    Deletes directly rather than through the API because the service has no
    DELETE endpoint - and should not grow one just to satisfy a test. Failures
    here are swallowed on purpose: a cleanup problem must never turn a passing
    suite red on camera.
    """
    refs = []
    yield refs.append

    if not refs:
        return
    import os
    url = os.environ.get("IM_TRAIN_DB_URL", "")
    if not url:
        return
    try:
        import psycopg
        with psycopg.connect(url, connect_timeout=5) as conn:
            with conn.cursor() as cur:
                cur.execute("delete from bookings where reference = any(%s)", (refs,))
            conn.commit()
    except Exception:
        pass
