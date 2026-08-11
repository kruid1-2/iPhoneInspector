from __future__ import annotations

from dataclasses import dataclass, fields
from typing import Any


class ConfigError(ValueError):
    pass


DEFAULT_WATCH_PROCESSES = (
    "SpringBoard",
    "backboardd",
    "runningboardd",
    "mediaserverd",
    "photoanalysisd",
    "kernel_task",
)

DEFAULT_LOG_KEYWORDS = (
    "thermal",
    "memory pressure",
    "jetsam",
    "watchdog",
    "hang",
    "springboard",
    "backboardd",
    "crash",
    "disk full",
    "i/o error",
    "power",
    "battery",
    "assertion",
    "runningboardd",
)


@dataclass(frozen=True, slots=True)
class SessionConfig:
    device_udid: str | None = None
    sample_interval_ms: int = 1_000
    battery_interval_ms: int = 2_000
    energy_interval_ms: int = 1_000
    summary_interval_ms: int = 2_000
    heartbeat_interval_ms: int = 5_000
    max_processes: int = 50
    max_log_events_per_interval: int = 10
    watch_process_names: tuple[str, ...] = DEFAULT_WATCH_PROCESSES
    energy_process_names: tuple[str, ...] = ("SpringBoard",)
    log_keywords: tuple[str, ...] = DEFAULT_LOG_KEYWORDS
    enable_sysmon: bool = True
    enable_battery: bool = True
    enable_energy: bool = True
    enable_oslog: bool = True
    enable_network: bool = True
    emit_log_messages: bool = False

    @classmethod
    def from_mapping(cls, raw: Any) -> "SessionConfig":
        if raw is None:
            raw = {}
        if not isinstance(raw, dict):
            raise ConfigError("config must be an object")

        allowed = {item.name for item in fields(cls)}
        unknown = sorted(set(raw) - allowed)
        if unknown:
            raise ConfigError(f"unknown config keys: {', '.join(unknown)}")

        values = dict(raw)
        for key in (
            "watch_process_names",
            "energy_process_names",
            "log_keywords",
        ):
            if key in values:
                item = values[key]
                if not isinstance(item, list) or not all(isinstance(entry, str) and entry for entry in item):
                    raise ConfigError(f"{key} must be an array of non-empty strings")
                values[key] = tuple(item)

        for key in (
            "enable_sysmon",
            "enable_battery",
            "enable_energy",
            "enable_oslog",
            "enable_network",
            "emit_log_messages",
        ):
            if key in values and not isinstance(values[key], bool):
                raise ConfigError(f"{key} must be a boolean")

        if "device_udid" in values and values["device_udid"] is not None:
            if not isinstance(values["device_udid"], str) or not values["device_udid"].strip():
                raise ConfigError("device_udid must be a non-empty string or null")
            values["device_udid"] = values["device_udid"].strip()

        result = cls(**values)
        result._validate_ranges()
        if result.enable_energy and not result.enable_sysmon:
            raise ConfigError("enable_energy requires enable_sysmon so existing PIDs can be selected read-only")
        return result

    def _validate_ranges(self) -> None:
        self._bounded("sample_interval_ms", self.sample_interval_ms, 500, 5_000)
        self._bounded("battery_interval_ms", self.battery_interval_ms, 1_000, 60_000)
        self._bounded("energy_interval_ms", self.energy_interval_ms, 500, 10_000)
        self._bounded("summary_interval_ms", self.summary_interval_ms, 1_000, 30_000)
        self._bounded("heartbeat_interval_ms", self.heartbeat_interval_ms, 1_000, 30_000)
        self._bounded("max_processes", self.max_processes, 1, 500)
        self._bounded("max_log_events_per_interval", self.max_log_events_per_interval, 0, 500)

    @staticmethod
    def _bounded(name: str, value: Any, minimum: int, maximum: int) -> None:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ConfigError(f"{name} must be an integer")
        if not minimum <= value <= maximum:
            raise ConfigError(f"{name} must be between {minimum} and {maximum}")

    def public_summary(self) -> dict[str, Any]:
        return {
            "sample_interval_ms": self.sample_interval_ms,
            "battery_interval_ms": self.battery_interval_ms,
            "energy_interval_ms": self.energy_interval_ms,
            "summary_interval_ms": self.summary_interval_ms,
            "heartbeat_interval_ms": self.heartbeat_interval_ms,
            "max_processes": self.max_processes,
            "watch_process_names": list(self.watch_process_names),
            "energy_process_names": list(self.energy_process_names),
            "log_keywords": list(self.log_keywords),
            "enable_sysmon": self.enable_sysmon,
            "enable_battery": self.enable_battery,
            "enable_energy": self.enable_energy,
            "enable_oslog": self.enable_oslog,
            "enable_network": self.enable_network,
            "emit_log_messages": self.emit_log_messages,
        }
