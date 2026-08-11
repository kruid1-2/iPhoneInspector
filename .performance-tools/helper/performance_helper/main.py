from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import logging
import signal
import sys
import time
from typing import Any

from . import __version__
from .config import ConfigError, SessionConfig
from .protocol import (
    EVENT_TYPES,
    MAX_COMMAND_BYTES,
    OUTPUT_QUEUE_CAPACITY,
    JsonlEmitter,
    PROTOCOL_VERSION,
    parse_command_line,
)
from .sanitizers import sanitize_text
from .session import (
    PerformanceSessionManager,
    backpressure_fixture_providers,
    failure_fixture_providers,
    fixture_providers,
    production_providers,
)
from .tunnel import DeviceRuntime, FixtureRuntime


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.WARNING)
    logging.getLogger("performance_helper").setLevel(logging.INFO)
    logging.getLogger("pymobiledevice3").setLevel(logging.CRITICAL)


async def open_stdin_reader() -> asyncio.StreamReader:
    reader = asyncio.StreamReader(limit=MAX_COMMAND_BYTES + 1)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    return reader


def _request_id(command: dict[str, Any]) -> str | int | None:
    value = command.get("request_id")
    return value if isinstance(value, (str, int)) and not isinstance(value, bool) else None


async def run(test_mode: str | None = None) -> int:
    configure_logging()
    lifecycle_logger = logging.getLogger("performance_helper.lifecycle")
    lifecycle_logger.info("helper process started")
    emitter = JsonlEmitter()
    await emitter.start()
    provider_factory = production_providers
    if test_mode == "fixture":
        provider_factory = fixture_providers
    elif test_mode == "backpressure":
        provider_factory = backpressure_fixture_providers
    elif test_mode == "provider_failure":
        provider_factory = failure_fixture_providers
    manager = PerformanceSessionManager(
        emitter,
        runtime_factory=FixtureRuntime if test_mode is not None else DeviceRuntime,
        provider_factory=provider_factory,
    )
    await emitter.emit(
        "helper_ready",
        {
            "helper_version": __version__,
            "protocol_version": PROTOCOL_VERSION,
            "pymobiledevice3_version": importlib.metadata.version("pymobiledevice3"),
            "python_version": sys.version.split()[0],
            "fixture_mode": test_mode is not None,
            "test_mode": test_mode,
            "read_only": True,
            "commands": ["start_session", "mark_lag", "stop_session", "shutdown"],
            "event_types": list(EVENT_TYPES),
            "stdout_contract": "jsonl_only",
            "output_queue_capacity": OUTPUT_QUEUE_CAPACITY,
        },
    )
    lifecycle_logger.info("helper_ready emitted")

    reader = await open_stdin_reader()
    lifecycle_logger.info("stdin reader ready")
    shutdown_requested = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, shutdown_requested.set)
        except NotImplementedError:
            pass

    while not shutdown_requested.is_set():
        read_task = asyncio.create_task(reader.readline())
        signal_task = asyncio.create_task(shutdown_requested.wait())
        done, pending = await asyncio.wait({read_task, signal_task}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        if signal_task in done and shutdown_requested.is_set():
            break
        line = read_task.result()
        if not line:
            await manager.shutdown()
            await emitter.emit("helper_shutdown", {"reason": "stdin_eof"})
            await emitter.close()
            return 0
        command: dict[str, Any] = {}
        try:
            command = parse_command_line(line)
            command_type = command["type"]
            request_id = _request_id(command)
            if command_type == "start_session":
                started = time.monotonic()
                lifecycle_logger.info("start_session received")
                config = SessionConfig.from_mapping(command.get("config", {}))
                session_id = await manager.start(config)
                lifecycle_logger.info(
                    "session started elapsed_ms=%d", round((time.monotonic() - started) * 1000)
                )
                await emitter.emit(
                    "command_ack",
                    {"command": command_type, "request_id": request_id, "accepted": True},
                    session_id=session_id,
                )
            elif command_type == "mark_lag":
                await manager.mark_lag(command.get("note", ""))
                await emitter.emit(
                    "command_ack",
                    {"command": command_type, "request_id": request_id, "accepted": True},
                    session_id=manager.session_id,
                )
            elif command_type == "stop_session":
                lifecycle_logger.info("stop_session received")
                active_session = manager.session_id
                await manager.stop()
                lifecycle_logger.info("session stopped")
                await emitter.emit(
                    "command_ack",
                    {"command": command_type, "request_id": request_id, "accepted": True},
                    session_id=active_session,
                )
            elif command_type == "shutdown":
                lifecycle_logger.info("shutdown begin")
                await manager.shutdown()
                await emitter.emit(
                    "helper_shutdown",
                    {"reason": "command", "request_id": request_id},
                )
                await emitter.close()
                lifecycle_logger.info("shutdown end")
                return 0
            else:
                raise ValueError(f"unsupported command type: {command_type}")
        except (ValueError, ConfigError, RuntimeError, OSError) as exc:
            await emitter.emit(
                "command_error",
                {
                    "request_id": _request_id(command),
                    "error_type": type(exc).__name__,
                    "error": sanitize_text(str(exc), limit=400, redact_network=True),
                    "state": manager.state,
                },
            )
        except BaseException as exc:
            logging.getLogger("performance_helper").error(
                "unexpected command failure: %s", sanitize_text(str(exc), limit=400, redact_network=True)
            )
            await emitter.emit(
                "command_error",
                {
                    "error_type": type(exc).__name__,
                    "error": "unexpected helper error",
                    "state": manager.state,
                },
            )

    await manager.shutdown()
    await emitter.emit("helper_shutdown", {"reason": "signal"})
    await emitter.close()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Read-only iPhone performance JSONL helper")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--fixture-mode",
        action="store_true",
        help="Use clearly labeled fixed test data and do not connect to a device.",
    )
    modes.add_argument(
        "--backpressure-test-mode",
        action="store_true",
        help="Emit high-rate labeled fixture data to validate bounded output queues.",
    )
    modes.add_argument(
        "--provider-failure-test-mode",
        action="store_true",
        help="Fail one labeled fixture provider while another continues.",
    )
    args = parser.parse_args()
    test_mode = None
    if args.fixture_mode:
        test_mode = "fixture"
    elif args.backpressure_test_mode:
        test_mode = "backpressure"
    elif args.provider_failure_test_mode:
        test_mode = "provider_failure"
    raise SystemExit(asyncio.run(run(test_mode=test_mode)))
