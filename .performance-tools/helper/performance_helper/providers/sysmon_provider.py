from __future__ import annotations

import dataclasses
import os
from typing import Any

from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap

from ..models import byte_metric, finite_number, metric
from .base import ProviderContext


PROCESS_BYTE_FIELDS = {
    "anonMemoryUsage",
    "diskBytesRead",
    "diskBytesWritten",
    "memAnon",
    "memCompressed",
    "memResidentSize",
    "memVirtualSize",
    "physFootprint",
    "purgeableMemory",
    "wiredMemory",
}

PRIMARY_PROCESS_FIELDS = (
    "pid",
    "ppid",
    "name",
    "comm",
    "execName",
    "cpuUsage",
    "physFootprint",
    "memResidentSize",
    "memVirtualSize",
    "procStatus",
    "threadCount",
    "diskBytesRead",
    "diskBytesWritten",
    "startAbsTime",
    "procAge",
    "powerScore",
    "totalEnergyScore",
)

MONITOR_OVERHEAD_NAMES = {"DTServiceHub", "sysmond", "remotepairingdeviced"}


def configure_output_frequency(sysmontap: Any, interval_ms: int) -> dict[str, Any]:
    """Align DVT's output flush frequency with the requested sample cadence.

    pymobiledevice3 10.2.3 configures ``ur`` to 1 ms even when ``sampleInterval``
    is much longer. Its own source labels ``ur`` as "Output frequency ms". The
    helper only needs one decoded update per requested sample, so retaining the
    1 ms flush rate wastes a full Mac CPU core without adding samples.
    """

    config = getattr(sysmontap, "_config", None)
    if not isinstance(config, dict) or "ur" not in config:
        return {"applied": False, "reason": "tap_config_unavailable"}
    previous = config.get("ur")
    config["ur"] = interval_ms
    return {
        "applied": True,
        "raw_field": "ur",
        "previous_ms": previous,
        "configured_ms": interval_ms,
        "source": "pymobiledevice3.sysmontap_config",
    }


def _process_name(raw: dict[str, Any]) -> str:
    value = raw.get("name") or raw.get("comm") or raw.get("execName") or "<unknown>"
    return os.path.basename(str(value))


def _process_number(raw: dict[str, Any], field: str) -> int | float:
    return finite_number(raw.get(field)) or 0


def normalize_process(raw: dict[str, Any]) -> dict[str, Any]:
    pid = raw.get("pid")
    item: dict[str, Any] = {
        "pid": pid if isinstance(pid, int) else None,
        "name": _process_name(raw),
        "monitor_overhead": _process_name(raw) in MONITOR_OVERHEAD_NAMES,
        "metrics": {},
    }
    for field in PRIMARY_PROCESS_FIELDS:
        if field in {"pid", "name", "comm", "execName"} or field not in raw:
            continue
        value = raw[field]
        if isinstance(value, (str, bool, int, float)) or value is None:
            if field in PROCESS_BYTE_FIELDS and isinstance(value, int) and not isinstance(value, bool):
                item["metrics"][field] = byte_metric(value, field)
            else:
                item["metrics"][field] = metric(value, field)

    extras: dict[str, Any] = {}
    primary = set(PRIMARY_PROCESS_FIELDS)
    for field, value in raw.items():
        if field in primary or isinstance(value, (bytes, bytearray)):
            continue
        if isinstance(value, (str, bool, int, float)) or value is None:
            extras[field] = metric(value, field)
    if extras:
        item["other_metrics"] = extras
    return item


def select_processes(
    processes: list[dict[str, Any]], max_processes: int, watch_names: tuple[str, ...]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    valid = [process for process in processes if isinstance(process.get("pid"), int)]
    by_cpu = sorted(valid, key=lambda item: _process_number(item, "cpuUsage"), reverse=True)
    by_memory = sorted(valid, key=lambda item: _process_number(item, "physFootprint"), reverse=True)
    selected: dict[int, dict[str, Any]] = {}

    watch_folded = {name.casefold() for name in watch_names}
    for process in valid:
        if _process_name(process).casefold() in watch_folded:
            selected[int(process["pid"])] = process
            if len(selected) >= max_processes:
                break

    ranked_pairs = zip(by_cpu, by_memory)
    for cpu_process, memory_process in ranked_pairs:
        for process in (cpu_process, memory_process):
            selected[int(process["pid"])] = process
            if len(selected) >= max_processes:
                break
        if len(selected) >= max_processes:
            break

    ordered = sorted(selected.values(), key=lambda item: _process_number(item, "cpuUsage"), reverse=True)
    normalized = [normalize_process(item) for item in ordered[:max_processes]]

    top_cpu = normalize_process(by_cpu[0]) if by_cpu else None
    top_memory = normalize_process(by_memory[0]) if by_memory else None
    return normalized, {
        "process_count": len(valid),
        "returned_process_count": len(normalized),
        "selection": "top_cpu_top_memory_and_watchlist",
        "truncated": len(valid) > len(normalized),
        "top_cpu_process": top_cpu,
        "top_memory_process": top_memory,
    }


def normalize_system(raw: dict[str, Any]) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for field, value in raw.items():
        if isinstance(value, (str, bool, int, float)) or value is None:
            if field in {"CPU_SystemLoad", "CPU_UserLoad"} and value == -1:
                unavailable = metric(None, field)
                unavailable.update({"availability": "unavailable", "raw_value": -1})
                metrics[field] = unavailable
                continue
            unit = "count" if field in {"CPUCount", "EnabledCPUs", "threadCount"} else None
            confidence = "field_semantics" if unit else "unknown"
            metrics[field] = metric(value, field, unit=unit, unit_confidence=confidence)
    return {
        "metrics": metrics,
        "limitations": [
            "CPU load fields are emitted as raw DVT values; their scale is not converted.",
            "VM counter units are not inferred because the device did not provide a page size.",
            "No process-CPU sum is used as a system-CPU substitute.",
        ],
    }


class SysmonProvider:
    name = "sysmon"

    async def run(self, context: ProviderContext) -> None:
        await context.emit(
            "provider_status",
            {"provider": self.name, "status": "starting"},
            self.name,
        )
        dvt = await context.dvt_for(self.name)
        sysmontap = await Sysmontap.create(dvt, interval=context.config.sample_interval_ms)
        output_frequency = configure_output_frequency(sysmontap, context.config.sample_interval_ms)
        system_raw: dict[str, Any] = {}
        cpu_usage_seen = False
        process_snapshot_seen = False
        async with sysmontap as sysmon:
            await context.emit(
                "provider_status",
                {
                    "provider": self.name,
                    "status": "running",
                    "sample_interval_ms": context.config.sample_interval_ms,
                    "output_frequency": output_frequency,
                    "process_fields": list(sysmon.process_attributes_cls.__dataclass_fields__),
                    "system_fields": list(sysmon.system_attributes_cls.__dataclass_fields__),
                },
                self.name,
            )
            async for row in sysmon:
                if context.stop_event.is_set():
                    break
                if "System" in row:
                    system_raw = dataclasses.asdict(sysmon.system_attributes_cls(*row["System"]))
                if "SystemCPUUsage" in row:
                    if cpu_usage_seen:
                        cpu_raw = row.get("SystemCPUUsage")
                        if isinstance(cpu_raw, dict):
                            merged = {**system_raw, **cpu_raw}
                            merged["CPUCount"] = row.get("CPUCount")
                            merged["EnabledCPUs"] = row.get("EnabledCPUs")
                            await context.emit("system_sample", normalize_system(merged), self.name)
                    else:
                        cpu_usage_seen = True
                if "Processes" in row:
                    raw_processes = []
                    for values in row["Processes"].values():
                        raw_processes.append(dataclasses.asdict(sysmon.process_attributes_cls(*values)))
                    context.process_registry.replace(raw_processes)
                    if not process_snapshot_seen:
                        process_snapshot_seen = True
                        continue
                    selected, summary = select_processes(
                        raw_processes,
                        context.config.max_processes,
                        context.config.watch_process_names,
                    )
                    await context.emit(
                        "process_batch",
                        {**summary, "processes": selected},
                        self.name,
                    )
