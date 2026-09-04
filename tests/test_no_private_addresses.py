"""Guard against a private LAN address reaching this public repo again.

2026-09-03: a "recover the baseline from the device" commit copied
calendar.sh off the Kindle byte-for-byte, including the real RFC1918
server address it had baked in on-device. It was caught before push, but
only by hand - nothing in the repo would have failed if it had gone out.
This test is that missing check: it scans every git-tracked file (not the
working tree, so a build artifact or a gitignored scratch file can't
trip it, and not history, so this only ever guards what is about to be
pushed) for anything in 10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16.

kindle-wall-display never needs one of these committed: the real address
belongs only to the private server's served copy of calendar.sh (see
kindle/trmnlcal/bin/calendar.sh's SERVER default, and the server-config
migration in this same test suite), never to this repo.
"""

from __future__ import annotations

import ipaddress
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# Loose enough to catch any dotted quad; ipaddress.ip_address() below is what
# actually decides whether it is a real, in-range, private address - so this
# does not need to be a precise IPv4 grammar and false positives from it
# (e.g. a version string) are filtered out by the parse step.
_DOTTED_QUAD = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")

_PRIVATE_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
]


def _is_rfc1918(candidate: str) -> bool:
    try:
        addr = ipaddress.ip_address(candidate)
    except ValueError:
        return False
    return any(addr in net for net in _PRIVATE_NETS)


def _tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT,
        capture_output=True,
        check=True,
    )
    names = result.stdout.decode("utf-8").split("\0")
    return [REPO_ROOT / name for name in names if name]


def _find_rfc1918_hits(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []  # binary (images, etc.) - not a place text addresses live
    return [m for m in _DOTTED_QUAD.findall(text) if _is_rfc1918(m)]


# This test file itself deliberately contains RFC1918 literals (to prove the
# detector works), so it is the one tracked file the real scan must skip -
# everything else in the repo is fair game.
_SELF = Path(__file__).resolve()


def test_no_rfc1918_address_in_tracked_files():
    offenders = {}
    for path in _tracked_files():
        if path.resolve() == _SELF:
            continue
        hits = _find_rfc1918_hits(path)
        if hits:
            offenders[str(path.relative_to(REPO_ROOT))] = hits

    assert not offenders, (
        "RFC1918 (private LAN) address(es) found in tracked files, which "
        f"must never be committed to this public repo: {offenders}. Replace "
        "with a placeholder (e.g. CHANGE_ME_SERVER_HOST) - the real address "
        "belongs only in the private server's served copy of calendar.sh."
    )


def test_scanner_actually_detects_a_private_address(tmp_path):
    """Null-model: prove the scanner isn't vacuously passing.

    Points the scanner at a throwaway file containing a real RFC1918
    address and confirms it gets flagged - otherwise a change that broke
    the regex or the ip-range check would leave the main test silently
    "passing" for the wrong reason.
    """
    planted = tmp_path / "planted.sh"
    planted.write_text('SERVER="http://192.168.1.195:8484"\n')
    hits = _find_rfc1918_hits(planted)
    assert hits == ["192.168.1.195"]


@pytest.mark.parametrize(
    "address,expected",
    [
        ("192.168.1.195", True),
        ("10.0.0.1", True),
        ("172.16.0.1", True),
        ("172.31.255.255", True),
        ("172.32.0.1", False),   # just outside 172.16.0.0/12
        ("172.15.255.255", False),  # just outside on the other side
        ("8.8.8.8", False),
        ("1.2.3.4", False),
    ],
)
def test_is_rfc1918_boundaries(address, expected):
    assert _is_rfc1918(address) is expected
