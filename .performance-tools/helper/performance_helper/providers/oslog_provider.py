from __future__ import annotations

import asyncio
import os
import time
from collections import Counter
from typing import Any

from pymobiledevice3.services.dvt.instruments.activity_trace_tap import ActivityTraceTap, decode_message_format

from ..sanitizers import sanitize_text
from .base import ProviderContext


def normalize_oslog_event(message: Any, keywords: tuple[str, ...], emit_message: bool) -> tuple[dict[str, Any], list[str]]:
    message_type = getattr(message, "message_type", None) or getattr(message, "event_type", None) or "unknown"
    subsystem = getattr(message, "subsystem", None)
    category = getattr(message, "category", None)
    pid = getattr(message, "process", None)
    sender_path = getattr(message, "sender_image_path", None)
    image_name = os.path.basename(str(sender_path)) if sender_path else None

    try:
        encoded_message = getattr(message, "message", None)
        decoded = decode_message_format(encoded_message) if encoded_message else str(getattr(message, "name", ""))
    except Exception:
        decoded = ""

    haystack = " ".join(str(part or "") for part in (message_type, subsystem, category, image_name, decoded)).casefold()
    matched = [keyword for keyword in keywords if keyword.casefold() in haystack]
    payload = {
        "pid": pid if isinstance(pid, int) else None,
        "process": sanitize_text(image_name or "<unknown>", limit=128),
        "level": sanitize_text(str(message_type), limit=64),
        "subsystem": sanitize_text(str(subsystem or ""), limit=160),
        "category": sanitize_text(str(category or ""), limit=160),
        "matched_keywords": matched,
        "candidate_tags": [f"candidate:{keyword}" for keyword in matched],
        "message_preview": sanitize_text(decoded, limit=300, redact_network=True) if emit_message else None,
        "raw_fields": {
            "pid": "process",
            "process": "sender_image_path",
            "level": "message_type/event_type",
            "subsystem": "subsystem",
            "category": "category",
            "message_preview": "message/name",
        },
        "interpretation": "keyword_match_only_not_a_fault_diagnosis",
        "diagnostic_conclusion": False,
    }
    return payload, matched


def is_notable_event(payload: dict[str, Any], matched: list[str]) -> bool:
    level = str(payload.get("level", "")).casefold()
    if level in {"error", "fault"}:
        return True
    anomaly_terms = {
        "thermal",
        "memory pressure",
        "jetsam",
        "watchdog",
        "hang",
        "crash",
        "disk full",
        "i/o error",
        "assertion",
    }
    return any(keyword.casefold() in anomaly_terms for keyword in matched)


class OslogProvider:
    name = "oslog"

    async def run(self, context: ProviderContext) -> None:
        levels: Counter[str] = Counter()
        keyword_counts: Counter[str] = Counter()
        total = emitted = dropped = 0
        interval_started = time.monotonic()

        dvt = await context.dvt_for(self.name)
        async with ActivityTraceTap(dvt) as tap:
            await context.emit(
                "provider_status",
                {
                    "provider": self.name,
                    "status": "running",
                    "summary_interval_ms": context.config.summary_interval_ms,
                    "full_messages_emitted": context.config.emit_log_messages,
                    "filtering": "keyword events plus aggregate summaries",
                },
                self.name,
            )
            async for message in tap:
                if context.stop_event.is_set():
                    break
                payload, matched = normalize_oslog_event(
                    message,
                    context.config.log_keywords,
                    context.config.emit_log_messages,
                )
                total += 1
                levels[str(payload["level"])] += 1
                keyword_counts.update(matched)
                if matched and is_notable_event(payload, matched):
                    if emitted < context.config.max_log_events_per_interval:
                        await context.emit("log_event", payload, self.name)
                        emitted += 1
                    else:
                        dropped += 1

                if (time.monotonic() - interval_started) * 1000 >= context.config.summary_interval_ms:
                    await context.emit(
                        "log_summary",
                        {
                            "events_seen": total,
                            "keyword_events_emitted": emitted,
                            "keyword_events_rate_limited": dropped,
                            "levels": dict(levels),
                            "keyword_counts": dict(keyword_counts),
                            "full_log_retained": False,
                        },
                        self.name,
                    )
                    levels.clear()
                    keyword_counts.clear()
                    total = emitted = dropped = 0
                    interval_started = time.monotonic()
                if total % 25 == 0:
                    # ActivityTraceTap can decode a large frame without another socket await.
                    # Yield explicitly so sysmon and control messages keep their cadence.
                    await asyncio.sleep(0)

        if total or emitted or dropped:
            await context.emit(
                "log_summary",
                {
                    "events_seen": total,
                    "keyword_events_emitted": emitted,
                    "keyword_events_rate_limited": dropped,
                    "levels": dict(levels),
                    "keyword_counts": dict(keyword_counts),
                    "full_log_retained": False,
                },
                self.name,
            )
