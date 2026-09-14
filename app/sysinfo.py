"""System facts for the Status page.

This module is the reason the Status page is worth filming: it reads the real
deployment state from `bootc status --json` and the real installed dependency
versions from importlib.metadata. Nothing here is hardcoded, so what appears on
screen in Act 4 changed because the image changed.

Everything degrades gracefully. On a laptop with no bootc, the bootc fields come
back as None and the page still renders.
"""
import json
import platform
import shutil
import subprocess
from importlib import metadata

# Dependencies surfaced on the Status page, in display order. The first entry is
# the demo subject and is rendered large.
TRACKED_PACKAGES = ["jinja2", "markupsafe", "fastapi", "uvicorn"]

# A remediated Lightwell artifact carries a PEP 440 local version segment.
# Java uses ".rhlw-0000X"; Python cannot (not valid PEP 440) and uses a local
# version instead, e.g. "2.11.3+rhlw00001".
LIGHTWELL_MARKER = "rhlw"


def _run(args):
    if not shutil.which(args[0]):
        return None
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=10)
    except (subprocess.SubprocessError, OSError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def os_release():
    """Parse /etc/os-release into a dict."""
    fields = {}
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                fields[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return fields


def bootc_status():
    """Deployment state from `bootc status --json`.

    Returns a dict with image, digest, version and rollback availability, or
    all-None when bootc is not present.
    """
    blank = {
        "image": None,
        "digest": None,
        "image_version": None,
        "rollback_available": False,
        "staged_pending_reboot": False,
    }

    raw = _run(["bootc", "status", "--json"])
    if not raw:
        return blank

    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return blank

    status = doc.get("status", {})
    booted = status.get("booted") or {}
    image_block = booted.get("image") or {}
    spec = image_block.get("image") or {}

    return {
        "image": spec.get("image"),
        "digest": image_block.get("imageDigest"),
        "image_version": image_block.get("version"),
        "rollback_available": bool(status.get("rollback")),
        "staged_pending_reboot": bool(status.get("staged")),
    }


def dependency_versions():
    """Installed versions of the tracked packages."""
    versions = {}
    for name in TRACKED_PACKAGES:
        try:
            versions[name] = metadata.version(name)
        except metadata.PackageNotFoundError:
            versions[name] = None
    return versions


def lightwell_state():
    """Whether the demo subject is currently a Lightwell-remediated artifact.

    Deliberately a string check on the version, not a claim about the code. It
    reports what is installed; the test suite is what proves the fix works.
    """
    try:
        version = metadata.version("jinja2")
    except metadata.PackageNotFoundError:
        return {"package": "jinja2", "version": None, "remediated": False}

    return {
        "package": "jinja2",
        "version": version,
        "remediated": LIGHTWELL_MARKER in version.lower(),
    }


def collect(tier):
    rel = os_release()
    boot = bootc_status()
    return {
        "tier": tier,
        "hostname": platform.node(),
        "os_name": rel.get("NAME"),
        "os_version": rel.get("VERSION_ID"),
        "arch": platform.machine(),
        "image": boot["image"],
        "digest": boot["digest"],
        "image_version": boot["image_version"],
        "rollback_available": boot["rollback_available"],
        "staged_pending_reboot": boot["staged_pending_reboot"],
        "image_mode": boot["image"] is not None,
        "dependencies": dependency_versions(),
        "lightwell": lightwell_state(),
    }
