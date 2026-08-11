from __future__ import annotations

import json
from pathlib import Path

from .base import ProviderContext, wait_interval
from .battery_provider import normalize_battery
from .energy_provider import normalize_energy
from .network_provider import NetworkAggregator
from .sysmon_provider import normalize_system, select_processes


class FixtureProvider:
    name = "fixture"

    def __init__(self, fixture_directory: Path) -> None:
        self.fixture_directory = fixture_directory

    def _load(self, name: str):
        return json.loads((self.fixture_directory / name).read_text(encoding="utf-8"))

    async def run(self, context: ProviderContext) -> None:
        await context.emit(
            "provider_status",
            {"provider": self.name, "status": "running", "is_fixture": True},
            self.name,
        )
        system = self._load("system.json")
        processes = self._load("processes.json")
        battery = self._load("battery.json")
        energy = self._load("energy.json")
        context.process_registry.replace(processes)
        selected, summary = select_processes(
            processes,
            context.config.max_processes,
            context.config.watch_process_names,
        )
        while not context.stop_event.is_set():
            await context.emit("system_sample", {**normalize_system(system), "is_fixture": True}, self.name)
            await context.emit(
                "process_batch",
                {**summary, "processes": selected, "is_fixture": True},
                self.name,
            )
            await context.emit("battery_sample", {**normalize_battery(battery), "is_fixture": True}, self.name)
            await context.emit(
                "energy_sample",
                {
                    **normalize_energy(energy, [55], {55: "SpringBoard"}),
                    "is_fixture": True,
                },
                self.name,
            )
            aggregate = NetworkAggregator()
            await context.emit(
                "network_summary",
                {**aggregate.snapshot_and_reset(), "is_fixture": True},
                self.name,
            )
            if await wait_interval(context.stop_event, context.config.sample_interval_ms / 1000):
                break


class BackpressureFixtureProvider:
    """High-rate, explicit fixture stream used only to validate bounded output."""

    name = "backpressure_fixture"

    async def run(self, context: ProviderContext) -> None:
        index = 0
        while not context.stop_event.is_set():
            for _ in range(50):
                await context.emit(
                    "log_event",
                    {
                        "is_fixture": True,
                        "candidate_tags": ["candidate:backpressure-test"],
                        "diagnostic_conclusion": False,
                        "index": index,
                        "padding": "x" * 512,
                    },
                    self.name,
                )
                index += 1
            if await wait_interval(context.stop_event, 0.005):
                break


class ControlledFailureProvider:
    """Raises one deterministic exception without touching an iPhone."""

    name = "controlled_failure"

    async def run(self, context: ProviderContext) -> None:
        raise RuntimeError("controlled non-core provider failure")
