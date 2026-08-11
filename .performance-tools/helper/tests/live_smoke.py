#!/usr/bin/env python3
"""Streaming stability acceptance harness that never saves full Helper JSONL."""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import re
import select
import statistics
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import psutil


TRACKED_TYPES = (
    "system_sample",
    "process_batch",
    "battery_sample",
    "energy_sample",
    "log_event",
    "log_summary",
    "network_summary",
    "heartbeat",
)


@dataclass
class TimingStats:
    count: int = 0
    first_ns: int | None = None
    last_ns: int | None = None
    previous_ns: int | None = None
    interval_total_ms: float = 0.0
    max_gap_ms: float = 0.0

    def observe(self, monotonic_ns: int) -> None:
        self.count += 1
        self.first_ns = monotonic_ns if self.first_ns is None else self.first_ns
        self.last_ns = monotonic_ns
        if self.previous_ns is not None:
            interval_ms = (monotonic_ns - self.previous_ns) / 1_000_000
            self.interval_total_ms += interval_ms
            self.max_gap_ms = max(self.max_gap_ms, interval_ms)
        self.previous_ns = monotonic_ns

    def summary(self) -> dict[str, Any]:
        intervals = max(0, self.count - 1)
        return {
            "count": self.count,
            "observed_span_seconds": round(((self.last_ns or 0) - (self.first_ns or 0)) / 1e9, 3)
            if self.count
            else 0,
            "average_interval_ms": round(self.interval_total_ms / intervals, 3) if intervals else None,
            "max_gap_ms": round(self.max_gap_ms, 3) if intervals else None,
        }


def send(process: subprocess.Popen[str], command: dict[str, Any]) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
    process.stdin.flush()


def parse_utc(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def recursive_keys(value: Any) -> set[str]:
    result: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            result.add(str(key))
            result.update(recursive_keys(child))
    elif isinstance(value, list):
        for child in value:
            result.update(recursive_keys(child))
    return result


def linear_slope_per_minute(samples: list[dict[str, Any]], field: str) -> float | None:
    points = [(sample["elapsed_seconds"], sample.get(field)) for sample in samples if sample.get(field) is not None]
    if len(points) < 2:
        return None
    xs = [point[0] for point in points]
    ys = [float(point[1]) for point in points]
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    if denominator == 0:
        return None
    slope_per_second = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denominator
    return slope_per_second * 60


def _safe_process_value(callback: Any) -> Any:
    try:
        return callback()
    except (psutil.Error, PermissionError, OSError):
        return None


def resource_sample(helper: psutil.Process, session_started_at: float, include_cpu: bool) -> dict[str, Any] | None:
    if not helper.is_running():
        return None
    cpu_percent = _safe_process_value(lambda: helper.cpu_percent(None)) if include_cpu else None
    memory_info = _safe_process_value(helper.memory_info)
    children = _safe_process_value(lambda: helper.children(recursive=True))
    return {
        "elapsed_seconds": round(time.monotonic() - session_started_at, 3),
        "pid": helper.pid,
        "cpu_percent": cpu_percent,
        "rss_bytes": memory_info.rss if memory_info is not None else None,
        "thread_count": _safe_process_value(helper.num_threads),
        "open_file_count": _safe_process_value(helper.num_fds) if hasattr(helper, "num_fds") else None,
        "child_process_count": len(children) if children is not None else None,
    }


class AcceptanceState:
    def __init__(self) -> None:
        self.counts: collections.Counter[str] = collections.Counter()
        self.timings = {name: TimingStats() for name in TRACKED_TYPES}
        self.protocol_versions: set[int] = set()
        self.session_ids: set[str] = set()
        self.parse_error_count = 0
        self.timestamp_error_count = 0
        self.timestamp_alias_mismatch_count = 0
        self.sequence_strict = True
        self.monotonic_strict = True
        self.previous_sequence: int | None = None
        self.previous_monotonic: int | None = None
        self.session_started_count = 0
        self.session_ended_count = 0
        self.session_started_ns: int | None = None
        self.session_ended_ns: int | None = None
        self.session_ended_payload: dict[str, Any] = {}
        self.mark_lag_count = 0
        self.mark_lag_session_match = True
        self.active_session_id: str | None = None
        self.provider_errors: collections.Counter[str] = collections.Counter()
        self.command_errors: list[dict[str, Any]] = []
        self.latest_queue: dict[str, Any] = {}
        self.latest_cadence: dict[str, Any] = {}
        self.data_quality: dict[str, Any] = {
            "system_cpu_raw_without_percent_unit": None,
            "negative_cpu_fields_unavailable": None,
            "vm_page_counts_not_converted_to_bytes": None,
            "process_memory_mib_conversion_correct": None,
            "observer_overhead_marked": None,
            "battery_temperature_not_cpu_temperature": None,
            "battery_health_not_percent": None,
            "energy_not_watts_or_joules": None,
            "network_has_no_endpoints_ports_or_payloads": None,
            "negative_pid_attribution_false": None,
            "oslog_sensitive_content_redacted": None,
            "oslog_keywords_are_candidates_only": None,
        }

    def observe(self, record: dict[str, Any]) -> None:
        event_type = record.get("type")
        self.counts[str(event_type)] += 1
        version = record.get("protocol_version")
        if isinstance(version, int):
            self.protocol_versions.add(version)
        sequence = record.get("sequence")
        monotonic_ns = record.get("monotonic_ns")
        if isinstance(sequence, int):
            if self.previous_sequence is not None and sequence <= self.previous_sequence:
                self.sequence_strict = False
            self.previous_sequence = sequence
        else:
            self.sequence_strict = False
        if isinstance(monotonic_ns, int):
            if self.previous_monotonic is not None and monotonic_ns <= self.previous_monotonic:
                self.monotonic_strict = False
            self.previous_monotonic = monotonic_ns
            if event_type in self.timings:
                self.timings[event_type].observe(monotonic_ns)
        else:
            self.monotonic_strict = False
        if not parse_utc(record.get("timestamp_utc")):
            self.timestamp_error_count += 1
        if record.get("timestamp") != record.get("timestamp_utc"):
            self.timestamp_alias_mismatch_count += 1

        session_id = record.get("session_id")
        if isinstance(session_id, str):
            self.session_ids.add(session_id)
        payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}

        if event_type == "session_started":
            self.session_started_count += 1
            self.active_session_id = session_id
            self.session_started_ns = monotonic_ns
        elif event_type == "session_ended":
            self.session_ended_count += 1
            self.session_ended_ns = monotonic_ns
            self.session_ended_payload = payload
            self.latest_queue = payload.get("output_queue", self.latest_queue)
            self.latest_cadence = payload.get("cadence", self.latest_cadence)
        elif event_type == "lag_marker":
            self.mark_lag_count += 1
            if session_id != self.active_session_id:
                self.mark_lag_session_match = False
        elif event_type == "provider_error":
            self.provider_errors[str(payload.get("provider", "unknown"))] += 1
        elif event_type == "command_error":
            self.command_errors.append(
                {
                    "error_type": payload.get("error_type"),
                    "error": payload.get("error"),
                    "request_type": payload.get("request_type"),
                }
            )
        elif event_type == "heartbeat":
            self.latest_queue = payload.get("output_queue", self.latest_queue)
            self.latest_cadence = payload.get("cadence", self.latest_cadence)

        if event_type == "system_sample":
            metrics = payload.get("metrics", {})
            total = metrics.get("CPU_TotalLoad", {})
            self.data_quality["system_cpu_raw_without_percent_unit"] = total.get("unit") is None
            negative = [metrics.get(name) for name in ("CPU_SystemLoad", "CPU_UserLoad")]
            negative = [item for item in negative if isinstance(item, dict) and item.get("raw_value") == -1]
            if negative:
                self.data_quality["negative_cpu_fields_unavailable"] = all(
                    item.get("availability") == "unavailable" and item.get("value") is None for item in negative
                )
            vm_fields = [item for name, item in metrics.items() if name.startswith("vm") and name.endswith("Count")]
            self.data_quality["vm_page_counts_not_converted_to_bytes"] = all(
                isinstance(item, dict) and item.get("unit") is None for item in vm_fields
            )
        elif event_type == "process_batch":
            conversion_results = []
            overhead_results = []
            for process in payload.get("processes", []):
                metrics = process.get("metrics", {})
                for name in ("physFootprint", "memResidentSize", "memVirtualSize"):
                    item = metrics.get(name)
                    if isinstance(item, dict) and isinstance(item.get("value"), int):
                        expected = round(item["value"] / 1_048_576, 3)
                        conversion_results.append(
                            item.get("display_unit") == "MiB" and math.isclose(item.get("display_value"), expected)
                        )
                if process.get("name") in {"DTServiceHub", "sysmond", "remotepairingdeviced"}:
                    overhead_results.append(process.get("monitor_overhead") is True)
            if conversion_results:
                self.data_quality["process_memory_mib_conversion_correct"] = all(conversion_results)
            if overhead_results:
                self.data_quality["observer_overhead_marked"] = all(overhead_results)
        elif event_type == "battery_sample":
            metrics = payload.get("metrics", {})
            limitations = " ".join(payload.get("limitations", [])).casefold()
            if "Temperature" in metrics:
                self.data_quality["battery_temperature_not_cpu_temperature"] = (
                    "battery telemetry" in limitations and "not cpu" in limitations
                )
            health = metrics.get("BatteryHealthMetric")
            if isinstance(health, dict):
                self.data_quality["battery_health_not_percent"] = health.get("unit") != "percent"
        elif event_type == "energy_sample":
            units = [item.get("unit") for item in payload.get("metrics", {}).values() if isinstance(item, dict)]
            self.data_quality["energy_not_watts_or_joules"] = all(unit not in {"watts", "joules", "W", "J"} for unit in units)
        elif event_type == "network_summary":
            keys = {key.casefold() for key in recursive_keys(payload)}
            forbidden = {"local_address", "remote_address", "port", "payload", "domain", "hostname"}
            serialized = json.dumps(payload, ensure_ascii=False)
            has_address = bool(re.search(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)", serialized))
            self.data_quality["network_has_no_endpoints_ports_or_payloads"] = not bool(keys & forbidden) and not has_address
            if payload.get("process_attribution_available") is False:
                self.data_quality["negative_pid_attribution_false"] = True
        elif event_type == "log_event":
            preview = payload.get("message_preview")
            safe_preview = preview is None or (
                not re.search(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", str(preview))
                and not re.search(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)", str(preview))
            )
            self.data_quality["oslog_sensitive_content_redacted"] = safe_preview
            self.data_quality["oslog_keywords_are_candidates_only"] = (
                payload.get("diagnostic_conclusion") is False
                and all(str(tag).startswith("candidate:") for tag in payload.get("candidate_tags", []))
            )


def summarize_resources(samples: list[dict[str, Any]]) -> dict[str, Any]:
    cpu_values = [sample["cpu_percent"] for sample in samples if sample.get("cpu_percent") is not None]
    rss_values = [sample["rss_bytes"] for sample in samples if sample.get("rss_bytes") is not None]
    threads = [sample["thread_count"] for sample in samples if sample.get("thread_count") is not None]
    fds = [sample["open_file_count"] for sample in samples if sample.get("open_file_count") is not None]
    children = [sample["child_process_count"] for sample in samples if sample.get("child_process_count") is not None]
    monotonic_rss = bool(rss_values) and all(right >= left for left, right in zip(rss_values, rss_values[1:]))
    slope = linear_slope_per_minute(samples, "rss_bytes")
    net_growth = rss_values[-1] - rss_values[0] if len(rss_values) >= 2 else None
    likely_leak = bool(
        monotonic_rss
        and net_growth is not None
        and net_growth > max(10 * 1024 * 1024, rss_values[0] * 0.2)
    )
    return {
        "sample_count": len(samples),
        "pid_values": sorted({sample["pid"] for sample in samples}),
        "average_cpu_percent": round(statistics.fmean(cpu_values), 3) if cpu_values else None,
        "peak_cpu_percent": round(max(cpu_values), 3) if cpu_values else None,
        "initial_rss_bytes": rss_values[0] if rss_values else None,
        "maximum_rss_bytes": max(rss_values) if rss_values else None,
        "final_rss_bytes": rss_values[-1] if rss_values else None,
        "rss_net_growth_bytes": net_growth,
        "rss_slope_bytes_per_minute": round(slope, 3) if slope is not None else None,
        "rss_strictly_non_decreasing": monotonic_rss,
        "likely_resource_leak": likely_leak,
        "thread_count_range": [min(threads), max(threads)] if threads else None,
        "open_file_count_range": [min(fds), max(fds)] if fds else None,
        "maximum_child_process_count": max(children) if children else None,
    }


def provider_flags(provider_set: str) -> dict[str, bool]:
    enabled = {
        "enable_sysmon": provider_set in {"all", "balanced", "sysmon", "sysmon_energy"},
        "enable_battery": provider_set in {"all", "balanced", "battery"},
        "enable_energy": provider_set in {"all", "balanced", "sysmon_energy"},
        "enable_oslog": provider_set in {"all", "oslog"},
        "enable_network": provider_set in {"all", "balanced", "network"},
    }
    return enabled


def run_acceptance(
    mode: str,
    duration: float,
    pause_output_seconds: float,
    provider_set: str = "all",
) -> tuple[int, dict[str, Any]]:
    helper_dir = Path(__file__).resolve().parents[1]
    helper = helper_dir / "run_helper.sh"
    args = [str(helper)]
    if mode == "backpressure":
        args.append("--backpressure-test-mode")
    elif mode == "provider_failure":
        args.append("--provider-failure-test-mode")

    process = subprocess.Popen(
        args,
        cwd=helper_dir,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None and process.stderr is not None
    helper_process = psutil.Process(process.pid)
    helper_process.cpu_percent(None)

    state = AcceptanceState()
    errors: list[str] = []
    resources: list[dict[str, Any]] = []
    started_at = time.monotonic()
    live_since: float | None = None
    next_resource_at: float | None = None
    pause_until: float | None = None
    mark_sent = stop_sent = shutdown_sent = False
    forced_termination_used = False
    deadline = started_at + max(60.0, duration + 75.0)

    try:
        while time.monotonic() < deadline:
            now = time.monotonic()
            streams = [process.stderr]
            if pause_until is None or now >= pause_until:
                streams.append(process.stdout)
            readable, _, _ = select.select(streams, [], [], 0.25)
            for stream in readable:
                line = stream.readline()
                if stream is process.stderr:
                    if line:
                        errors.append(line.strip())
                    continue
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    state.parse_error_count += 1
                    continue
                if not isinstance(record, dict):
                    state.parse_error_count += 1
                    continue
                state.observe(record)
                event_type = record.get("type")
                if event_type == "helper_ready":
                    send(
                        process,
                        {
                            "type": "start_session",
                            "request_id": f"{mode}-start",
                            "config": {
                                "sample_interval_ms": 1000,
                                "battery_interval_ms": 2000,
                                "energy_interval_ms": 1000,
                                "summary_interval_ms": 2000,
                                "heartbeat_interval_ms": 5000,
                                "max_processes": 25,
                                "emit_log_messages": False,
                                **provider_flags(provider_set),
                            },
                        },
                    )
                elif event_type == "session_started":
                    live_since = time.monotonic()
                    next_resource_at = live_since
                    initial = resource_sample(helper_process, live_since, include_cpu=False)
                    if initial:
                        resources.append(initial)
                    if mode == "backpressure":
                        pause_until = live_since + pause_output_seconds
                elif event_type == "command_error" and live_since is None and not shutdown_sent:
                    send(process, {"type": "shutdown", "request_id": "after-start-error"})
                    shutdown_sent = True
                elif event_type == "session_ended" and not shutdown_sent:
                    final = resource_sample(helper_process, live_since or started_at, include_cpu=True)
                    if final:
                        resources.append(final)
                    send(process, {"type": "shutdown", "request_id": f"{mode}-shutdown"})
                    shutdown_sent = True
                elif event_type == "helper_shutdown":
                    break

            now = time.monotonic()
            if live_since is not None and next_resource_at is not None and now >= next_resource_at + 5:
                sample = resource_sample(helper_process, live_since, include_cpu=True)
                if sample:
                    resources.append(sample)
                next_resource_at = now
            if live_since is not None and mode != "backpressure" and not mark_sent and now - live_since >= duration / 2:
                send(process, {"type": "mark_lag", "note": "稳定性验收测试标记"})
                mark_sent = True
            if live_since is not None and not stop_sent and now - live_since >= duration:
                send(process, {"type": "stop_session", "request_id": f"{mode}-stop"})
                stop_sent = True
            if state.counts["helper_shutdown"]:
                break
            if process.poll() is not None:
                break

        try:
            return_code = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forced_termination_used = True
            process.terminate()
            try:
                return_code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                return_code = process.wait(timeout=3)
    finally:
        if process.poll() is None:
            forced_termination_used = True
            process.terminate()
            process.wait(timeout=5)

    session_duration = None
    if state.session_started_ns is not None and state.session_ended_ns is not None:
        session_duration = (state.session_ended_ns - state.session_started_ns) / 1e9
    queue = state.session_ended_payload.get("output_queue", state.latest_queue)
    cadence = state.session_ended_payload.get("cadence", state.latest_cadence)
    provider_states = state.session_ended_payload.get("provider_states", {})
    provider_runtimes = state.session_ended_payload.get("provider_runtime_ms", {})
    provider_error_count = state.session_ended_payload.get(
        "provider_error_count", sum(state.provider_errors.values())
    )

    summary = {
        "mode": mode,
        "provider_set": provider_set,
        "exit_code": return_code,
        "forced_termination_used": forced_termination_used,
        "wall_time_seconds": round(time.monotonic() - started_at, 3),
        "session_duration_seconds": round(session_duration, 3) if session_duration is not None else None,
        "stdout": {
            "pure_jsonl": state.parse_error_count == 0,
            "parse_error_count": state.parse_error_count,
            "protocol_versions": sorted(state.protocol_versions),
            "sequence_strictly_increasing": state.sequence_strict,
            "monotonic_ns_strictly_increasing": state.monotonic_strict,
            "timestamp_utc_error_count": state.timestamp_error_count,
            "timestamp_alias_mismatch_count": state.timestamp_alias_mismatch_count,
            "session_ids_seen": len(state.session_ids),
        },
        "lifecycle": {
            "session_started_count": state.session_started_count,
            "session_ended_count": state.session_ended_count,
            "mark_lag_count": state.mark_lag_count,
            "mark_lag_session_match": state.mark_lag_session_match,
            "cleanup_complete": state.session_ended_payload.get("cleanup_complete"),
            "stop_reason": state.session_ended_payload.get("reason"),
        },
        "message_counts": dict(sorted(state.counts.items())),
        "message_timings": {name: state.timings[name].summary() for name in TRACKED_TYPES},
        "providers": {
            "states": provider_states,
            "runtime_ms": provider_runtimes,
            "provider_error_count": provider_error_count,
            "provider_errors_observed": dict(state.provider_errors),
            "unexpected_provider_exit_count": state.session_ended_payload.get("unexpected_provider_exit_count"),
            "reconnect_count": state.session_ended_payload.get("reconnect_count"),
        },
        "queue": queue,
        "cadence": cadence,
        "resources": summarize_resources(resources),
        "data_quality": state.data_quality,
        "stderr_line_count": len(errors),
        "stderr_lines": errors[:12],
        "command_errors": state.command_errors[:6],
    }
    success = (
        return_code == 0
        and not forced_termination_used
        and summary["stdout"]["pure_jsonl"]
        and summary["stdout"]["sequence_strictly_increasing"]
        and summary["stdout"]["monotonic_ns_strictly_increasing"]
        and state.session_started_count == 1
        and state.session_ended_count == 1
        and state.counts["helper_shutdown"] == 1
    )
    return (0 if success else 1), summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("production", "backpressure", "provider_failure"), default="production")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--pause-output-seconds", type=float, default=3.0)
    parser.add_argument(
        "--provider-set",
        choices=("all", "balanced", "sysmon", "sysmon_energy", "battery", "oslog", "network"),
        default="all",
    )
    args = parser.parse_args()
    duration = max(3.0, min(args.duration, 300.0))
    code, summary = run_acceptance(
        args.mode,
        duration,
        max(1.0, min(args.pause_output_seconds, 10.0)),
        args.provider_set,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    raise SystemExit(code)


if __name__ == "__main__":
    main()
