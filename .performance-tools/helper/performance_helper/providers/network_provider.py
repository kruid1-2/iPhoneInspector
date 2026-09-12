from __future__ import annotations

import asyncio
import time
from collections import Counter
from typing import Any

from pymobiledevice3.services.dvt.instruments.network_monitor import (
    ConnectionDetectionEvent,
    ConnectionUpdateEvent,
    InterfaceDetectionEvent,
    NetworkMonitor,
)

from .base import ProviderContext


class NetworkAggregator:
    def __init__(self) -> None:
        self.interfaces: dict[int, str] = {}
        self.connections: dict[int, dict[str, Any]] = {}
        self.previous: dict[int, tuple[int, int, int, int]] = {}
        self.detected = 0
        self.rx_bytes = 0
        self.tx_bytes = 0
        self.rx_packets = 0
        self.tx_packets = 0
        self.by_interface: Counter[str] = Counter()
        self.by_kind: Counter[str] = Counter()
        self.by_pid: Counter[int] = Counter()

    def consume(self, event: Any) -> None:
        if isinstance(event, InterfaceDetectionEvent):
            self.interfaces[event.interface_index] = event.name
            return
        if isinstance(event, ConnectionDetectionEvent):
            self.detected += 1
            self.connections[event.serial_number] = {
                "interface_index": event.interface_index,
                "pid": event.pid,
                "kind": event.kind,
            }
            interface = self.interfaces.get(event.interface_index, f"index:{event.interface_index}")
            self.by_interface[interface] += 1
            self.by_kind[str(event.kind)] += 1
            if event.pid >= 0:
                self.by_pid[event.pid] += 1
            return
        if isinstance(event, ConnectionUpdateEvent):
            previous = self.previous.get(event.connection_serial, (0, 0, 0, 0))
            raw_current = (event.rx_packets, event.rx_bytes, event.tx_packets, event.tx_bytes)
            current = tuple(
                value
                if isinstance(value, int) and not isinstance(value, bool) and value >= 0
                else previous[index]
                for index, value in enumerate(raw_current)
            )
            deltas = tuple(max(0, now - old) for now, old in zip(current, previous))
            self.previous[event.connection_serial] = current
            self.rx_packets += deltas[0]
            self.rx_bytes += deltas[1]
            self.tx_packets += deltas[2]
            self.tx_bytes += deltas[3]

    def snapshot_and_reset(self) -> dict[str, Any]:
        result = {
            "active_connections_observed": len(self.connections),
            "new_connections": self.detected,
            "rx_bytes_delta": self.rx_bytes,
            "tx_bytes_delta": self.tx_bytes,
            "rx_packets_delta": self.rx_packets,
            "tx_packets_delta": self.tx_packets,
            "connections_by_interface": dict(self.by_interface),
            "connections_by_raw_kind": dict(self.by_kind),
            "connections_by_pid": {str(pid): count for pid, count in self.by_pid.items()},
            "process_attribution_available": bool(self.by_pid),
            "process_association_available": bool(self.by_pid),
            "addresses_retained": False,
            "payloads_captured": False,
            "raw_fields": {
                "rx_bytes_delta": "rx_bytes",
                "tx_bytes_delta": "tx_bytes",
                "rx_packets_delta": "rx_packets",
                "tx_packets_delta": "tx_packets",
                "connections_by_raw_kind": "kind",
            },
            "limitations": [
                "Connection kind values are emitted without guessed semantics.",
                "Negative device PIDs are excluded from process association.",
                "Endpoint addresses, domains and payloads are never emitted.",
            ],
        }
        self.detected = 0
        self.rx_bytes = self.tx_bytes = self.rx_packets = self.tx_packets = 0
        self.by_interface.clear()
        self.by_kind.clear()
        self.by_pid.clear()
        return result


class NetworkProvider:
    name = "network"

    async def run(self, context: ProviderContext) -> None:
        aggregate = NetworkAggregator()
        interval_started = time.monotonic()
        dvt = await context.dvt_for(self.name)
        async with NetworkMonitor(dvt) as monitor:
            await context.emit(
                "provider_status",
                {
                    "provider": self.name,
                    "status": "running",
                    "summary_interval_ms": context.config.summary_interval_ms,
                    "privacy_mode": "aggregate_without_endpoints_or_payloads",
                },
                self.name,
            )
            async for event in monitor:
                if context.stop_event.is_set():
                    break
                if event is not None:
                    aggregate.consume(event)
                if (time.monotonic() - interval_started) * 1000 >= context.config.summary_interval_ms:
                    await context.emit("network_summary", aggregate.snapshot_and_reset(), self.name)
                    interval_started = time.monotonic()
                if (aggregate.detected + len(aggregate.previous)) % 25 == 0:
                    await asyncio.sleep(0)

        await context.emit("network_summary", aggregate.snapshot_and_reset(), self.name)
