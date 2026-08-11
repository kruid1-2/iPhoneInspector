from __future__ import annotations

import io
import json
import unittest

from performance_helper.config import ConfigError, SessionConfig
from performance_helper.protocol import BoundedEventBuffer, BufferedEvent, JsonlEmitter, parse_command_line


class ConfigTests(unittest.TestCase):
    def test_defaults_are_bounded_and_read_only_compatible(self) -> None:
        config = SessionConfig.from_mapping({})
        self.assertEqual(config.sample_interval_ms, 1000)
        self.assertTrue(config.enable_sysmon)
        self.assertFalse(config.emit_log_messages)

    def test_unknown_field_is_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            SessionConfig.from_mapping({"invented": True})

    def test_energy_requires_sysmon(self) -> None:
        with self.assertRaises(ConfigError):
            SessionConfig.from_mapping({"enable_sysmon": False, "enable_energy": True})

    def test_out_of_range_interval_is_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            SessionConfig.from_mapping({"sample_interval_ms": 100})


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_emitter_outputs_one_json_object_per_line(self) -> None:
        stream = io.StringIO()
        emitter = JsonlEmitter(stream)
        await emitter.emit("sample", {"value": float("nan"), "text": "ok"})
        await emitter.close()
        lines = stream.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertEqual(record["type"], "sample")
        self.assertIsNone(record["payload"]["value"])
        self.assertEqual(record["sequence"], 1)

    async def test_sequences_are_monotonic(self) -> None:
        stream = io.StringIO()
        emitter = JsonlEmitter(stream)
        await emitter.emit("one")
        await emitter.emit("two")
        await emitter.close()
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual([record["sequence"] for record in records], [1, 2])

    async def test_bounded_buffer_reports_drops_and_preserves_critical_event(self) -> None:
        buffer = BoundedEventBuffer(capacity=2)
        self.assertTrue(await buffer.put(BufferedEvent("one", "sample", "sysmon", False)))
        self.assertTrue(await buffer.put(BufferedEvent("two", "sample", "sysmon", False)))
        self.assertFalse(await buffer.put(BufferedEvent("three", "sample", "sysmon", False)))
        self.assertTrue(await buffer.put(BufferedEvent("critical", "provider_error", "energy", True)))
        stats = buffer.stats()
        self.assertEqual(stats["capacity"], 2)
        self.assertEqual(stats["high_watermark"], 2)
        self.assertEqual(stats["dropped_count"], 2)
        queued = []
        for _ in range(2):
            item = await buffer.get()
            queued.append(item.event_type)
            await buffer.task_done()
        self.assertIn("provider_error", queued)
        await buffer.close()

    def test_command_parser_rejects_non_object(self) -> None:
        with self.assertRaises(ValueError):
            parse_command_line("[]")

    def test_command_parser_accepts_utf8_json(self) -> None:
        command = parse_command_line('{"type":"mark_lag","note":"切换 App"}')
        self.assertEqual(command["type"], "mark_lag")
