from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


HELPER_DIR = Path(__file__).resolve().parents[1]


class CliIntegrationTests(unittest.TestCase):
    def test_fixture_control_protocol_is_jsonl_only(self) -> None:
        commands = "\n".join(
            [
                '{"type":"start_session","config":{},"request_id":"s"}',
                '{"type":"mark_lag","note":"fixture lag","request_id":"m"}',
                '{"type":"stop_session","request_id":"e"}',
                '{"type":"shutdown","request_id":"q"}',
            ]
        ) + "\n"
        result = subprocess.run(
            [sys.executable, "-m", "performance_helper", "--fixture-mode"],
            cwd=HELPER_DIR,
            input=commands,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertGreaterEqual(len(records), 8)
        self.assertEqual(records[0]["type"], "helper_ready")
        self.assertTrue(records[0]["payload"]["fixture_mode"])
        self.assertEqual(records[-1]["type"], "helper_shutdown")
        self.assertTrue(all(record["protocol_version"] == 2 for record in records))
        self.assertTrue(all(record["timestamp"] == record["timestamp_utc"] for record in records))
