from __future__ import annotations

import asyncio
from typing import Any

from pymobiledevice3.services.dvt.instruments.energy_monitor import EnergyMonitor

from ..models import metric
from .base import ProviderContext, wait_interval


def _flatten_primitives(value: Any, prefix: str = "", limit: int = 256) -> dict[str, Any]:
    result: dict[str, Any] = {}

    def visit(item: Any, path: str) -> None:
        if len(result) >= limit:
            return
        if isinstance(item, dict):
            for key, child in item.items():
                child_path = f"{path}.{key}" if path else str(key)
                visit(child, child_path)
        elif isinstance(item, (list, tuple)):
            for index, child in enumerate(item):
                visit(child, f"{path}[{index}]")
        elif isinstance(item, (str, bool, int, float)) or item is None:
            result[path or "value"] = metric(item, path or "value")

    visit(value, prefix)
    return result


def normalize_energy(raw: Any, target_pids: list[int], names_by_pid: dict[int, str]) -> dict[str, Any]:
    return {
        "target_processes": [
            {"pid": pid, "name": names_by_pid.get(pid, "<unknown>")} for pid in target_pids
        ],
        "metrics": _flatten_primitives(raw),
        "limitations": [
            "Energy values are emitted as raw Instruments debug-gauge scores.",
            "They are not labeled as watts or joules and are not converted.",
            "Sampling is intentionally throttled to limit monitor overhead.",
        ],
    }


class EnergyProvider:
    name = "energy"

    async def run(self, context: ProviderContext) -> None:
        await context.emit(
            "provider_status",
            {
                "provider": self.name,
                "status": "waiting_for_processes",
                "process_names": list(context.config.energy_process_names),
            },
            self.name,
        )
        dvt = await context.dvt_for(self.name)
        last_targets: list[int] | None = None
        while not context.stop_event.is_set():
            target_pids = context.process_registry.pids_for_names(context.config.energy_process_names)
            if not target_pids:
                context.process_registry.updated.clear()
                try:
                    await asyncio.wait_for(context.process_registry.updated.wait(), timeout=1.0)
                except TimeoutError:
                    continue
                continue

            names_by_pid = {pid: context.process_registry.name_for_pid(pid) or "<unknown>" for pid in target_pids}
            if target_pids != last_targets:
                await context.emit(
                    "provider_status",
                    {
                        "provider": self.name,
                        "status": "running",
                        "sample_interval_ms": context.config.energy_interval_ms,
                        "targets": [names_by_pid[pid] for pid in target_pids],
                    },
                    self.name,
                )
                last_targets = target_pids

            async with EnergyMonitor(dvt, target_pids) as monitor:
                async for telemetry in monitor:
                    if context.stop_event.is_set():
                        return
                    await context.emit(
                        "energy_sample",
                        normalize_energy(telemetry, target_pids, names_by_pid),
                        self.name,
                    )
                    if await wait_interval(context.stop_event, context.config.energy_interval_ms / 1000):
                        return
                    current_targets = context.process_registry.pids_for_names(context.config.energy_process_names)
                    if current_targets != target_pids:
                        break
