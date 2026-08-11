from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from collections import Counter, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, TextIO

from .sanitizers import to_safe_json


PROTOCOL_VERSION = 2
MAX_COMMAND_BYTES = 65_536
OUTPUT_QUEUE_CAPACITY = 256

EVENT_TYPES = (
    "helper_ready",
    "session_started",
    "system_sample",
    "process_batch",
    "battery_sample",
    "energy_sample",
    "log_event",
    "log_summary",
    "network_summary",
    "heartbeat",
    "stream_gap",
    "lag_marker",
    "provider_status",
    "provider_error",
    "session_ended",
    "command_ack",
    "command_error",
    "helper_shutdown",
)

CRITICAL_EVENT_TYPES = {
    "helper_ready",
    "session_started",
    "heartbeat",
    "stream_gap",
    "lag_marker",
    "provider_status",
    "provider_error",
    "session_ended",
    "command_ack",
    "command_error",
    "helper_shutdown",
}


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@dataclass(slots=True)
class BufferedEvent:
    line: str
    event_type: str
    source: str
    critical: bool


class BoundedEventBuffer:
    """Bounded FIFO with explicit drop accounting and critical-event admission."""

    def __init__(self, capacity: int = OUTPUT_QUEUE_CAPACITY) -> None:
        if capacity < 1:
            raise ValueError("buffer capacity must be positive")
        self.capacity = capacity
        self._items: deque[BufferedEvent] = deque()
        self._condition = asyncio.Condition()
        self._closed = False
        self._in_flight = 0
        self.high_watermark = 0
        self.dropped_count = 0
        self.dropped_by_type: Counter[str] = Counter()
        self.dropped_by_source: Counter[str] = Counter()

    def _record_drop(self, item: BufferedEvent) -> None:
        self.dropped_count += 1
        self.dropped_by_type[item.event_type] += 1
        self.dropped_by_source[item.source] += 1

    async def put(self, item: BufferedEvent) -> bool:
        async with self._condition:
            if self._closed:
                raise RuntimeError("output buffer is closed")
            if len(self._items) >= self.capacity:
                if not item.critical:
                    self._record_drop(item)
                    return False
                evicted_index = next(
                    (index for index, queued in enumerate(self._items) if not queued.critical),
                    None,
                )
                if evicted_index is not None:
                    evicted = self._items[evicted_index]
                    del self._items[evicted_index]
                    self._record_drop(evicted)
                else:
                    await self._condition.wait_for(lambda: len(self._items) < self.capacity or self._closed)
                    if self._closed:
                        raise RuntimeError("output buffer is closed")
            self._items.append(item)
            self.high_watermark = max(self.high_watermark, len(self._items))
            self._condition.notify_all()
            return True

    async def get(self) -> BufferedEvent | None:
        async with self._condition:
            await self._condition.wait_for(lambda: bool(self._items) or self._closed)
            if not self._items:
                return None
            item = self._items.popleft()
            self._in_flight += 1
            self._condition.notify_all()
            return item

    async def task_done(self) -> None:
        async with self._condition:
            self._in_flight = max(0, self._in_flight - 1)
            self._condition.notify_all()

    async def flush(self) -> None:
        async with self._condition:
            await self._condition.wait_for(lambda: not self._items and self._in_flight == 0)

    async def close(self) -> None:
        async with self._condition:
            self._closed = True
            self._condition.notify_all()

    def stats(self) -> dict[str, Any]:
        return {
            "capacity": self.capacity,
            "current_occupancy": len(self._items),
            "in_flight": self._in_flight,
            "high_watermark": self.high_watermark,
            "drop_policy": "drop_new_noncritical_or_evict_oldest_noncritical_for_critical",
            "dropped_count": self.dropped_count,
            "dropped_by_type": dict(self.dropped_by_type),
            "dropped_by_source": dict(self.dropped_by_source),
        }


class JsonlEmitter:
    """The only production writer permitted to touch stdout."""

    def __init__(self, stream: TextIO | None = None, *, capacity: int = OUTPUT_QUEUE_CAPACITY) -> None:
        self._stream = stream or sys.stdout
        self._sequence = 0
        self._sequence_lock = asyncio.Lock()
        self._counts: Counter[str] = Counter()
        self._buffer = BoundedEventBuffer(capacity)
        self._writer_task: asyncio.Task[None] | None = None
        self._writer_error: BaseException | None = None
        self._fd: int | None = None
        self._fd_was_blocking: bool | None = None

    async def start(self) -> None:
        if self._writer_task is not None:
            return
        try:
            self._fd = self._stream.fileno()
        except (AttributeError, OSError):
            self._fd = None
        if self._fd is not None:
            self._fd_was_blocking = os.get_blocking(self._fd)
            os.set_blocking(self._fd, False)
        self._writer_task = asyncio.create_task(self._writer_loop(), name="jsonl-writer")

    async def emit(
        self,
        event_type: str,
        payload: dict[str, Any] | None = None,
        *,
        source: str = "helper",
        session_id: str | None = None,
    ) -> dict[str, Any] | None:
        await self.start()
        if self._writer_error is not None:
            raise RuntimeError("JSONL writer is unavailable") from self._writer_error
        async with self._sequence_lock:
            self._sequence += 1
            timestamp = utc_timestamp()
            record = {
                "protocol_version": PROTOCOL_VERSION,
                "type": event_type,
                "timestamp": timestamp,
                "timestamp_utc": timestamp,
                "monotonic_ns": time.monotonic_ns(),
                "sequence": self._sequence,
                "session_id": session_id,
                "source": source,
                "payload": to_safe_json(payload or {}, redact_network=source in {"network", "oslog"}),
            }
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            accepted = await self._buffer.put(
                BufferedEvent(
                    line=line,
                    event_type=event_type,
                    source=source,
                    critical=event_type in CRITICAL_EVENT_TYPES,
                )
            )
            if accepted:
                self._counts[event_type] += 1
                return record
            return None

    async def _writer_loop(self) -> None:
        try:
            while True:
                item = await self._buffer.get()
                if item is None:
                    return
                try:
                    await self._write_line(item.line + "\n")
                finally:
                    await self._buffer.task_done()
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            self._writer_error = exc
            raise

    async def _write_line(self, line: str) -> None:
        if self._fd is None:
            self._stream.write(line)
            self._stream.flush()
            return
        data = line.encode("utf-8")
        offset = 0
        loop = asyncio.get_running_loop()
        while offset < len(data):
            try:
                offset += os.write(self._fd, data[offset:])
            except BlockingIOError:
                ready = loop.create_future()
                def mark_ready() -> None:
                    if not ready.done():
                        ready.set_result(None)

                loop.add_writer(self._fd, mark_ready)
                try:
                    await ready
                finally:
                    loop.remove_writer(self._fd)

    async def flush(self) -> None:
        await self.start()
        await self._buffer.flush()
        if self._writer_error is not None:
            raise RuntimeError("JSONL writer failed") from self._writer_error

    async def close(self) -> None:
        if self._writer_task is None:
            return
        await self.flush()
        await self._buffer.close()
        await self._writer_task
        self._writer_task = None
        if self._fd is not None and self._fd_was_blocking is not None:
            os.set_blocking(self._fd, self._fd_was_blocking)

    def event_counts(self) -> dict[str, int]:
        return dict(self._counts)

    def queue_stats(self) -> dict[str, Any]:
        return self._buffer.stats()


def parse_command_line(line: bytes | str) -> dict[str, Any]:
    raw = line.encode("utf-8") if isinstance(line, str) else line
    if len(raw) > MAX_COMMAND_BYTES:
        raise ValueError("command exceeds 65536 bytes")
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("command must be UTF-8") from exc
    try:
        command = json.loads(decoded)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON at column {exc.colno}") from exc
    if not isinstance(command, dict):
        raise ValueError("command must be a JSON object")
    command_type = command.get("type")
    if not isinstance(command_type, str) or not command_type:
        raise ValueError("command.type must be a non-empty string")
    return command
