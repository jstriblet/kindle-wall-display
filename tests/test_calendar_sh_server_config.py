"""TDD for the server-address OTA migration (see docs/server-address-migration.md).

The public repo can never carry Jonathan's real LAN address (see
test_no_private_addresses.py), but the device still has to know a real
address to talk to. The fix is a two-step OTA migration:

  Step 1 (this repo's current calendar.sh): still resolves SERVER from a
  literal default (a placeholder here; the real address only in the
  private server's served copy), but writes whatever it resolved into
  SERVER_CONFIG_FILE the first time that file is absent.

  Step 2 (a later revision, shipped only after confirming step 1 landed
  on the device - see the migration doc): drops the literal default
  entirely and reads SERVER_CONFIG_FILE instead, failing loudly rather
  than silently pointing nowhere if that file is missing.

This file tests step 1's half of the contract: config is written when
absent, and never overwritten once it exists. Step 2's half (read
preferred over any default; missing config fails loudly) is tested in
test_calendar_sh_server_config_step2.py, added in the commit that ships
step 2.
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
    env["TRMNL_FBINK"] = "/nonexistent-fbink-for-tests"
    env.update(env_overrides or {})
    return subprocess.run(
        ["sh", str(SCRIPT), mode],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def test_seeds_server_config_when_absent(tmp_path):
    config_file = tmp_path / "server.conf"
    assert not config_file.exists()

    result = run_calendar_sh("stop", tmp_path, {"TRMNL_SERVER": "http://test-seed.example:1234"})

    assert config_file.is_file(), (
        f"expected {config_file} to be written on first run; "
        f"rc={result.returncode} stderr={result.stderr!r}"
    )
    assert config_file.read_text().strip() == "http://test-seed.example:1234"


def test_does_not_overwrite_existing_server_config(tmp_path):
    config_file = tmp_path / "server.conf"
    config_file.write_text("http://already-configured.example:9999\n")

    run_calendar_sh("stop", tmp_path, {"TRMNL_SERVER": "http://should-not-be-written.example:1234"})

    assert config_file.read_text().strip() == "http://already-configured.example:9999"


def test_seeding_runs_on_every_entrypoint_not_just_start(tmp_path):
    """"stop", "probe", or any other mode all pass through the same shared
    entrypoints setup (see calendar.sh's own comment above check_update_probation),
    so the seed must not be wired to only one of them."""
    config_file = tmp_path / "server.conf"

    run_calendar_sh("probe", tmp_path, {"TRMNL_SERVER": "http://from-probe.example:1234"})

    assert config_file.is_file()
    assert config_file.read_text().strip() == "http://from-probe.example:1234"
