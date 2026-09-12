from __future__ import annotations

import math
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Any


def finite_number(value: Any) -> int | float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    return None


def metric(
    value: Any,
    raw_field: str,
    *,
    unit: str | None = None,
    unit_confidence: str = "unknown",
) -> dict[str, Any]:
    """Wrap a value with traceable source-field and unit metadata."""
    return {
        "value": value,
        "raw_field": raw_field,
        "unit": unit,
        "unit_confidence": unit_confidence,
    }


def byte_metric(value: Any, raw_field: str) -> dict[str, Any]:
    result = metric(value, raw_field, unit="bytes", unit_confidence="pymobiledevice3_byte_field")
    if isinstance(value, int) and not isinstance(value, bool):
        result.update(
            {
                "display_value": round(value / 1_048_576, 3),
                "display_unit": "MiB",
                "conversion": "bytes/1048576",
            }
        )
    return result


@dataclass(slots=True)
class ProcessRegistry:
    """Latest process identity map shared with the energy provider."""

    by_name: dict[str, list[int]] = field(default_factory=dict)
    by_pid: dict[int, str] = field(default_factory=dict)
    generation: int = 0
    updated: Any = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if self.updated is None:
            import asyncio

            self.updated = asyncio.Event()

    def replace(self, processes: list[dict[str, Any]]) -> None:
        by_name: dict[str, list[int]] = {}
        by_pid: dict[int, str] = {}
        for process in processes:
            pid = process.get("pid")
            name = process.get("name") or process.get("comm") or process.get("execName")
            if not isinstance(pid, int) or not isinstance(name, str) or not name:
                continue
            by_pid[pid] = name
            by_name.setdefault(name, []).append(pid)
        self.by_name = by_name
        self.by_pid = by_pid
        self.generation += 1
        self.updated.set()

    def pids_for_names(self, names: tuple[str, ...]) -> list[int]:
        selected: list[int] = []
        folded = {name.casefold() for name in names}
        for pid, name in self.by_pid.items():
            if name.casefold() in folded:
                selected.append(pid)
        return sorted(set(selected))

    def name_for_pid(self, pid: int) -> str | None:
        return self.by_pid.get(pid)


@dataclass(slots=True)
class CadenceTracker:
    expected_interval_ms: dict[str, int]
    last_seen_ns: dict[str, int] = field(default_factory=dict)
    gap_count: int = 0
    gaps_by_type: Counter[str] = field(default_factory=Counter)

    def observe(self, event_type: str, source: str) -> dict[str, Any] | None:
        expected = self.expected_interval_ms.get(event_type)
        if expected is None:
            return None
        now_ns = time.monotonic_ns()
        previous = self.last_seen_ns.get(event_type)
        self.last_seen_ns[event_type] = now_ns
        if previous is None:
            return None
        observed_ms = (now_ns - previous) / 1_000_000
        threshold_ms = max(expected * 2.5, expected + 1_000)
        if observed_ms <= threshold_ms:
            return None
        self.gap_count += 1
        self.gaps_by_type[event_type] += 1
        return {
            "stream": event_type,
            "provider": source,
            "expected_interval_ms": expected,
            "observed_gap_ms": round(observed_ms, 3),
            "threshold_ms": round(threshold_ms, 3),
            "gap_index": self.gap_count,
            "interpretation": "observed_stream_gap_not_repeated_or_interpolated",
        }

    def stats(self) -> dict[str, Any]:
        return {
            "stream_gap_count": self.gap_count,
            "stream_gaps_by_type": dict(self.gaps_by_type),
        }
