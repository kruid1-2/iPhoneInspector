from __future__ import annotations

import asyncio
import io
import json
import unittest

from performance_helper.config import SessionConfig
from performance_helper.protocol import JsonlEmitter
from performance_helper.session import PerformanceSessionManager, SessionStateError


class FakeRuntime:
    lockdown = object()
    closed = False

    def __init__(self, requested_udid=None):
        self.requested_udid = requested_udid

    async def open(self):
        return None

    def device_summary(self):
        return {"device_ref": "fake", "is_fixture": True}

    async def dvt_for(self, provider_name):
        return object()

    async def close(self):
        self.closed = True


class FakeProvider:
    name = "fake"

    async def run(self, context):
        await context.emit("system_sample", {"is_fixture": True}, self.name)
        await context.stop_event.wait()


class FailingProvider:
    name = "energy"

    async def run(self, context):
        raise RuntimeError("controlled provider failure")


class ContinuingProvider:
    name = "network"

    async def run(self, context):
        while not context.stop_event.is_set():
            await context.emit("network_summary", {"is_fixture": True}, self.name)
            await asyncio.sleep(0.01)


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.stream = io.StringIO()
        self.emitter = JsonlEmitter(self.stream)
        self.manager = PerformanceSessionManager(
            self.emitter,
            runtime_factory=FakeRuntime,
            provider_factory=lambda config: [FakeProvider()],
        )

    def records(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines()]

    async def asyncTearDown(self):
        await self.emitter.close()

    async def test_start_mark_stop_lifecycle(self):
        session_id = await self.manager.start(SessionConfig.from_mapping({}))
        await asyncio.sleep(0)
        await self.manager.mark_lag("切换 App 时卡顿")
        runtime = self.manager.runtime
        await self.manager.stop()
        await self.emitter.flush()
        types = [record["type"] for record in self.records()]
        self.assertIn("session_started", types)
        self.assertIn("system_sample", types)
        self.assertIn("lag_marker", types)
        self.assertIn("session_ended", types)
        self.assertTrue(runtime.closed)
        self.assertEqual(self.manager.state, "idle")
        self.assertTrue(all(record["session_id"] in {session_id, None} for record in self.records()))

    async def test_second_start_is_rejected(self):
        await self.manager.start(SessionConfig.from_mapping({}))
        with self.assertRaises(SessionStateError):
            await self.manager.start(SessionConfig.from_mapping({}))
        await self.manager.stop()

    async def test_empty_provider_set_stops_cleanly(self):
        manager = PerformanceSessionManager(
            self.emitter,
            runtime_factory=FakeRuntime,
            provider_factory=lambda config: [],
        )
        await manager.start(SessionConfig.from_mapping({}))
        await manager.stop()
        self.assertEqual(manager.state, "idle")

    async def test_provider_failure_is_isolated(self):
        manager = PerformanceSessionManager(
            self.emitter,
            runtime_factory=FakeRuntime,
            provider_factory=lambda config: [FailingProvider(), ContinuingProvider()],
        )
        await manager.start(SessionConfig.from_mapping({"enable_energy": False}))
        await asyncio.sleep(0.06)
        self.assertEqual(manager.state, "running")
        await manager.stop()
        await self.emitter.flush()
        records = self.records()
        errors = [record for record in records if record["type"] == "provider_error"]
        network = [record for record in records if record["type"] == "network_summary"]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["payload"]["provider"], "energy")
        self.assertTrue(errors[0]["payload"]["isolated"])
        self.assertGreaterEqual(len(network), 2)
        self.assertEqual(records[-1]["type"], "session_ended")
