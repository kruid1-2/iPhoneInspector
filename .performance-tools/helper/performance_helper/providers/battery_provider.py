from __future__ import annotations

from typing import Any

from pymobiledevice3.services.diagnostics import DiagnosticsService

from ..models import metric
from .base import ProviderContext, wait_interval


BATTERY_FIELDS = (
    "CurrentCapacity",
    "IsCharging",
    "ExternalConnected",
    "FullyCharged",
    "InstantAmperage",
    "Voltage",
    "Temperature",
    "CycleCount",
    "DesignCapacity",
    "NominalChargeCapacity",
    "AppleRawMaxCapacity",
    "MaxCapacity",
    "BatteryHealthMetric",
)


def normalize_battery(raw: dict[str, Any]) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for field in BATTERY_FIELDS:
        if field not in raw:
            continue
        value = raw[field]
        unit = None
        confidence = "unknown"
        if field == "CurrentCapacity":
            unit = "percent"
            confidence = "field_semantics"
        elif field in {"CycleCount"}:
            unit = "count"
            confidence = "field_semantics"
        elif field in {"IsCharging", "ExternalConnected", "FullyCharged"}:
            unit = "boolean"
            confidence = "field_semantics"
        metrics[field] = metric(value, field, unit=unit, unit_confidence=confidence)

    telemetry = raw.get("PowerTelemetryData")
    telemetry_metrics: dict[str, Any] = {}
    if isinstance(telemetry, dict):
        for field, value in list(telemetry.items())[:128]:
            if isinstance(value, (bool, int, float)) or value is None:
                raw_field = f"PowerTelemetryData.{field}"
                telemetry_metrics[field] = metric(value, raw_field)

    return {
        "metrics": metrics,
        "power_telemetry_metrics": telemetry_metrics,
        "missing_fields": [field for field in BATTERY_FIELDS if field not in raw],
        "limitations": [
            "Temperature is battery telemetry, not CPU or SoC temperature.",
            "Voltage, current, temperature and capacity units are not converted until confirmed.",
            "Instantaneous power is not calculated while current sign and units remain unconfirmed.",
            "BatteryHealthMetric is not treated as a health percentage.",
        ],
    }


class BatteryProvider:
    name = "battery"

    async def run(self, context: ProviderContext) -> None:
        async with DiagnosticsService(context.lockdown) as diagnostics:
            await context.emit(
                "provider_status",
                {
                    "provider": self.name,
                    "status": "running",
                    "sample_interval_ms": context.config.battery_interval_ms,
                },
                self.name,
            )
            while not context.stop_event.is_set():
                raw = await diagnostics.get_battery()
                if raw is None:
                    await context.emit(
                        "battery_sample",
                        {"availability": "device_returned_no_data", "metrics": {}},
                        self.name,
                    )
                else:
                    await context.emit("battery_sample", normalize_battery(raw), self.name)
                if await wait_interval(context.stop_event, context.config.battery_interval_ms / 1000):
                    break
