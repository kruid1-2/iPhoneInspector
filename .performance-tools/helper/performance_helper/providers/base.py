from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Protocol

from ..config import SessionConfig
from ..models import CadenceTracker, ProcessRegistry
from ..protocol import JsonlEmitter


@dataclass(slots=True)
class ProviderContext:
    dvt_resolver: Callable[[str], Awaitable[Any]]
    lockdown: Any
    emitter: JsonlEmitter
    session_id: str
    config: SessionConfig
    process_registry: ProcessRegistry
    cadence_tracker: CadenceTracker
    stop_event: asyncio.Event

    async def emit(self, event_type: str, payload: dict[str, Any], source: str) -> None:
        gap = self.cadence_tracker.observe(event_type, source)
        if gap is not None:
            await self.emitter.emit("stream_gap", gap, source="scheduler", session_id=self.session_id)
        await self.emitter.emit(event_type, payload, source=source, session_id=self.session_id)

    async def dvt_for(self, provider_name: str) -> Any:
        return await self.dvt_resolver(provider_name)


class Provider(Protocol):
    name: str

    async def run(self, context: ProviderContext) -> None: ...


async def wait_interval(stop_event: asyncio.Event, seconds: float) -> bool:
    """Return True when stopped, False when the interval elapsed."""
    try:
        await asyncio.wait_for(stop_event.wait(), timeout=seconds)
        return True
    except TimeoutError:
        return False
