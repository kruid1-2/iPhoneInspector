from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .config import SessionConfig
from .models import CadenceTracker, ProcessRegistry
from .protocol import JsonlEmitter
from .providers import BatteryProvider, EnergyProvider, NetworkProvider, OslogProvider, SysmonProvider
from .providers.base import Provider, ProviderContext
from .providers.fixture_provider import BackpressureFixtureProvider, ControlledFailureProvider, FixtureProvider
from .sanitizers import sanitize_note, sanitize_text
from .tunnel import DeviceRuntime, FixtureRuntime


RuntimeFactory = Callable[[str | None], Any]
ProviderFactory = Callable[[SessionConfig], list[Provider]]


def production_providers(config: SessionConfig) -> list[Provider]:
    providers: list[Provider] = []
    if config.enable_sysmon:
        providers.append(SysmonProvider())
    if config.enable_battery:
        providers.append(BatteryProvider())
    if config.enable_energy:
        providers.append(EnergyProvider())
    if config.enable_oslog:
        providers.append(OslogProvider())
    if config.enable_network:
        providers.append(NetworkProvider())
    return providers


def fixture_providers(config: SessionConfig) -> list[Provider]:
    fixture_dir = Path(__file__).resolve().parent.parent / "tests" / "fixtures"
    return [FixtureProvider(fixture_dir)]


def backpressure_fixture_providers(config: SessionConfig) -> list[Provider]:
    return [BackpressureFixtureProvider()]


def failure_fixture_providers(config: SessionConfig) -> list[Provider]:
    return [ControlledFailureProvider(), *fixture_providers(config)]


class SessionStateError(RuntimeError):
    pass


class PerformanceSessionManager:
    def __init__(
        self,
        emitter: JsonlEmitter,
        *,
        runtime_factory: RuntimeFactory = DeviceRuntime,
        provider_factory: ProviderFactory = production_providers,
    ) -> None:
        self.emitter = emitter
        self.runtime_factory = runtime_factory
        self.provider_factory = provider_factory
        self.state = "idle"
        self.session_id: str | None = None
        self.config: SessionConfig | None = None
        self.runtime: Any = None
        self.stop_event: asyncio.Event | None = None
        self.tasks: list[asyncio.Task[None]] = []
        self.started_monotonic = 0.0
        self.lag_markers = 0
        self._counts_at_start: dict[str, int] = {}
        self.provider_states: dict[str, str] = {}
        self.provider_error_counts: dict[str, int] = {}
        self.provider_started_ns: dict[str, int] = {}
        self.provider_ended_ns: dict[str, int] = {}
        self.unexpected_provider_exit_count = 0
        self.reconnect_count = 0
        self.cadence_tracker: CadenceTracker | None = None
        self.logger = logging.getLogger("performance_helper.session")

    async def start(self, config: SessionConfig) -> str:
        if self.state != "idle":
            raise SessionStateError(f"cannot start while session state is {self.state}")
        self.state = "starting"
        session_id = str(uuid.uuid4())
        runtime = self.runtime_factory(config.device_udid)
        try:
            runtime_started = time.monotonic()
            self.logger.info("RSD runtime setup begin")
            await asyncio.wait_for(runtime.open(), timeout=30.0)
            self.logger.info(
                "RSD runtime setup end elapsed_ms=%d", round((time.monotonic() - runtime_started) * 1000)
            )
        except BaseException as exc:
            self.logger.error("RSD runtime setup failed error_type=%s", type(exc).__name__)
            self.state = "idle"
            raise

        self.session_id = session_id
        self.config = config
        self.runtime = runtime
        self.stop_event = asyncio.Event()
        self.started_monotonic = time.monotonic()
        self.lag_markers = 0
        self._counts_at_start = self.emitter.event_counts()
        self.provider_states = {}
        self.provider_error_counts = {}
        self.provider_started_ns = {}
        self.provider_ended_ns = {}
        self.unexpected_provider_exit_count = 0
        self.reconnect_count = 0
        self.cadence_tracker = CadenceTracker(
            {
                "system_sample": config.sample_interval_ms,
                "process_batch": config.sample_interval_ms,
                "battery_sample": config.battery_interval_ms,
                "energy_sample": config.energy_interval_ms,
                "log_summary": config.summary_interval_ms,
                "network_summary": config.summary_interval_ms,
            }
        )
        self.state = "running"

        await self.emitter.emit(
            "session_started",
            {
                "state": self.state,
                "config": config.public_summary(),
                "device": runtime.device_summary(),
                "read_only": True,
            },
            session_id=session_id,
        )

        context = ProviderContext(
            dvt_resolver=runtime.dvt_for,
            lockdown=runtime.lockdown,
            emitter=self.emitter,
            session_id=session_id,
            config=config,
            process_registry=ProcessRegistry(),
            cadence_tracker=self.cadence_tracker,
            stop_event=self.stop_event,
        )
        providers = self.provider_factory(config)
        self.provider_states = {provider.name: "starting" for provider in providers}
        sysmon_providers = [provider for provider in providers if provider.name == "sysmon"]
        remaining_providers = [provider for provider in providers if provider.name != "sysmon"]
        self.tasks = [asyncio.create_task(self._heartbeat_loop(), name="heartbeat")]
        self.tasks.extend(
            asyncio.create_task(self._run_provider(provider, context), name=f"provider:{provider.name}")
            for provider in sysmon_providers
        )
        if sysmon_providers:
            try:
                await asyncio.wait_for(context.process_registry.updated.wait(), timeout=8.0)
            except TimeoutError:
                await context.emit(
                    "provider_status",
                    {
                        "provider": "sysmon",
                        "status": "readiness_timeout",
                        "continued_with_other_providers": True,
                    },
                    "sysmon",
                )
        self.tasks.extend(
            asyncio.create_task(self._run_provider(provider, context), name=f"provider:{provider.name}")
            for provider in remaining_providers
        )
        return session_id

    async def _run_provider(self, provider: Provider, context: ProviderContext) -> None:
        self.provider_states[provider.name] = "running"
        self.provider_started_ns[provider.name] = time.monotonic_ns()
        self.logger.info("provider startup begin provider=%s", provider.name)
        try:
            await provider.run(context)
            if context.stop_event.is_set():
                self.provider_states[provider.name] = "stopped"
            else:
                self.provider_states[provider.name] = "unexpected_exit"
                self.unexpected_provider_exit_count += 1
                await context.emit(
                    "provider_error",
                    {
                        "provider": provider.name,
                        "error_type": "UnexpectedProviderExit",
                        "error": "provider task ended while the session was still running",
                        "isolated": True,
                    },
                    provider.name,
                )
        except asyncio.CancelledError:
            self.provider_states[provider.name] = "cancelled"
            raise
        except BaseException as exc:
            message = sanitize_text(str(exc), limit=400, redact_network=True)
            self.provider_states[provider.name] = "failed"
            self.provider_error_counts[provider.name] = self.provider_error_counts.get(provider.name, 0) + 1
            self.logger.error("provider %s stopped: %s", provider.name, message)
            await context.emit(
                "provider_error",
                {
                    "provider": provider.name,
                    "error_type": type(exc).__name__,
                    "error": message,
                    "isolated": True,
                },
                provider.name,
            )
        finally:
            self.provider_ended_ns[provider.name] = time.monotonic_ns()
            runtime_ms = (self.provider_ended_ns[provider.name] - self.provider_started_ns[provider.name]) / 1_000_000
            self.logger.info("provider ended provider=%s runtime_ms=%.3f", provider.name, runtime_ms)

    async def _heartbeat_loop(self) -> None:
        assert self.config is not None
        assert self.stop_event is not None
        assert self.session_id is not None
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(
                    self.stop_event.wait(),
                    timeout=self.config.heartbeat_interval_ms / 1000,
                )
                return
            except TimeoutError:
                pass
            counts = self.emitter.event_counts()
            session_counts = {
                key: value - self._counts_at_start.get(key, 0)
                for key, value in counts.items()
                if value - self._counts_at_start.get(key, 0) > 0
            }
            await self.emitter.emit(
                "heartbeat",
                {
                    "state": self.state,
                    "elapsed_ms": round((time.monotonic() - self.started_monotonic) * 1000),
                    "provider_states": dict(self.provider_states),
                    "provider_error_count": sum(self.provider_error_counts.values()),
                    "unexpected_provider_exit_count": self.unexpected_provider_exit_count,
                    "reconnect_count": self.reconnect_count,
                    "message_counts": session_counts,
                    "output_queue": self.emitter.queue_stats(),
                    "cadence": self.cadence_tracker.stats() if self.cadence_tracker else {},
                },
                source="heartbeat",
                session_id=self.session_id,
            )

    async def mark_lag(self, note: Any) -> None:
        if self.state != "running" or self.session_id is None:
            raise SessionStateError("mark_lag requires a running session")
        self.lag_markers += 1
        await self.emitter.emit(
            "lag_marker",
            {
                "note": sanitize_note(note),
                "elapsed_ms": round((time.monotonic() - self.started_monotonic) * 1000),
                "marker_index": self.lag_markers,
            },
            source="user_marker",
            session_id=self.session_id,
        )

    async def stop(self, reason: str = "user_request") -> None:
        if self.state == "idle":
            raise SessionStateError("no session is running")
        if self.state == "stopping":
            return
        self.state = "stopping"
        session_id = self.session_id
        assert session_id is not None
        assert self.stop_event is not None
        self.stop_event.set()

        if self.tasks:
            done, pending = await asyncio.wait(self.tasks, timeout=3.0)
        else:
            done, pending = set(), set()
        cleanup_messages: list[str] = []
        for task in pending:
            task.cancel()
        if pending:
            try:
                await asyncio.wait_for(asyncio.gather(*pending, return_exceptions=True), timeout=5.0)
            except TimeoutError:
                cleanup_messages.append("provider cancellation exceeded 5 seconds")
        for task in done:
            with contextlib.suppress(asyncio.CancelledError):
                task.exception()

        try:
            await asyncio.wait_for(self.runtime.close(), timeout=8.0)
        except BaseException as exc:
            runtime_error = sanitize_text(str(exc), limit=400, redact_network=True)
            cleanup_messages.append(runtime_error or type(exc).__name__)
            self.logger.error("runtime cleanup failed: %s", runtime_error)

        current_counts = self.emitter.event_counts()
        event_counts = {
            key: value - self._counts_at_start.get(key, 0)
            for key, value in current_counts.items()
            if value - self._counts_at_start.get(key, 0) > 0
        }
        provider_runtime_ms = {}
        end_ns = time.monotonic_ns()
        for provider, started_ns in self.provider_started_ns.items():
            provider_runtime_ms[provider] = round(
                (self.provider_ended_ns.get(provider, end_ns) - started_ns) / 1_000_000,
                3,
            )
        await self.emitter.emit(
            "session_ended",
            {
                "reason": reason,
                "duration_ms": round((time.monotonic() - self.started_monotonic) * 1000),
                "lag_marker_count": self.lag_markers,
                "event_counts": event_counts,
                "provider_states": dict(self.provider_states),
                "provider_runtime_ms": provider_runtime_ms,
                "provider_error_counts": dict(self.provider_error_counts),
                "provider_error_count": sum(self.provider_error_counts.values()),
                "unexpected_provider_exit_count": self.unexpected_provider_exit_count,
                "reconnect_count": self.reconnect_count,
                "output_queue": self.emitter.queue_stats(),
                "cadence": self.cadence_tracker.stats() if self.cadence_tracker else {},
                "cleanup_complete": not cleanup_messages,
                "cleanup_error": "; ".join(cleanup_messages) if cleanup_messages else None,
            },
            session_id=session_id,
        )
        self.tasks = []
        self.runtime = None
        self.config = None
        self.stop_event = None
        self.session_id = None
        self.cadence_tracker = None
        self.state = "idle"

    async def shutdown(self) -> None:
        if self.state != "idle":
            await self.stop(reason="helper_shutdown")
