"""Tests for the server-address OTA migration's final state (step 2).

See test_no_private_addresses.py for why this repo can never commit
Jonathan's real LAN address, and kindle/trmnlcal/bin/calendar.sh's own
"no literal server address" comment for the migration this completes.

An earlier revision of this script (address migration step 1) wrote
SERVER_CONFIG_FILE ($BASE/server.conf) from whatever SERVER's literal
default was, the first time that file was absent. That revision's tests
(config seeded when absent, never overwritten once present) lived in this
same file and are superseded here: this revision no longer writes the
config file at all, only reads it, so those tests no longer describe its
contract. What replaces them:

  - the address is read from SERVER_CONFIG_FILE in preference to any
    built-in default (there is no built-in default any more - see below);
  - TRMNL_SERVER still overrides everything, matching every other TRMNL_*
    knob in this script;
  - a missing config file fails loudly (logged, drawn on-screen, exit 1)
    for any mode that would actually need a server, rather than silently
    resolving to nothing and failing every fetch with no clear reason;
  - stop/probe/ruler still work with no config, since they need no server
    and probe is the tool you would use to diagnose exactly this.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "kindle" / "trmnlcal" / "bin" / "calendar.sh"


def run_calendar_sh(mode: str, base: Path, env_overrides: dict | None = None, timeout: int = 10):
    env = dict(os.environ)
    env["TRMNL_BASE"] = str(base)
    env.setdefault("TRMNL_FBINK", "/nonexistent-fbink-for-tests")
    env.pop("TRMNL_SERVER", None)  # tests opt in to this explicitly
    env.update(env_overrides or {})
    return subprocess.run(
        ["sh", str(SCRIPT), mode],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _log_text(base: Path) -> str:
    log_file = base / "calendar.log"
    return log_file.read_text() if log_file.exists() else ""


def _make_fake_fbink(tmp_path: Path):
    fbink = tmp_path / "fake_fbink"
    calls_log = tmp_path / "fbink_calls.log"
    fbink.write_text('#!/bin/sh\necho "$@" >> "' + str(calls_log) + '"\n')
    fbink.chmod(0o755)
    return fbink, calls_log


def test_reads_server_from_config_file_when_present(tmp_path):
    (tmp_path / "server.conf").write_text("http://from-config.example:8484\n")

    run_calendar_sh("stop", tmp_path)

    assert "startup server=http://from-config.example:8484" in _log_text(tmp_path)


def test_env_override_takes_precedence_over_config_file(tmp_path):
    (tmp_path / "server.conf").write_text("http://from-config.example:8484\n")

    run_calendar_sh("stop", tmp_path, {"TRMNL_SERVER": "http://from-env.example:9999"})

    log = _log_text(tmp_path)
    assert "startup server=http://from-env.example:9999" in log
    assert "from-config.example" not in log


@pytest.mark.parametrize("mode", ["once", "start", "suspendtest"])
def test_missing_config_fails_loudly_for_network_modes(tmp_path, mode):
    fbink, calls_log = _make_fake_fbink(tmp_path)

    result = run_calendar_sh(mode, tmp_path, {"TRMNL_FBINK": str(fbink)})

    assert result.returncode == 1, f"expected {mode} to refuse to start; stderr={result.stderr!r}"
    assert "ERROR no server configured" in _log_text(tmp_path)
    assert calls_log.exists(), "expected the error card to be drawn on-screen via fbink"
    assert "NOT CONFIGURED" in calls_log.read_text()


@pytest.mark.parametrize("mode", ["stop", "probe"])
def test_missing_config_does_not_block_diagnostic_modes(tmp_path, mode):
    result = run_calendar_sh(mode, tmp_path)

    assert result.returncode == 0, f"{mode} should not need a server; stderr={result.stderr!r}"
    assert "ERROR no server configured" not in _log_text(tmp_path)


def test_missing_config_does_not_block_ruler_mode(tmp_path):
    # ruler's own exit code depends on a card asset this test doesn't ship
    # with, so it is checked separately from stop/probe above - the only
    # thing under test here is that the server-config guard let it through.
    run_calendar_sh("ruler", tmp_path)

    assert "ERROR no server configured" not in _log_text(tmp_path)
