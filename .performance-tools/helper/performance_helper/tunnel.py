from __future__ import annotations

import hashlib
import asyncio
import logging
import time
from contextlib import AsyncExitStack
from typing import Any

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.usbmux import MuxDevice, select_devices_by_connection_type


class DeviceSelectionError(RuntimeError):
    pass


def private_device_ref(serial: str) -> str:
    return "device-" + hashlib.sha256(serial.encode("utf-8")).hexdigest()[:12]


async def select_single_usb_device(requested_udid: str | None) -> MuxDevice:
    devices = await select_devices_by_connection_type("USB")
    if requested_udid is not None:
        devices = [device for device in devices if device.matches_udid(requested_udid)]
    if not devices:
        raise DeviceSelectionError("no matching trusted USB device was found")
    if len(devices) > 1:
        raise DeviceSelectionError("multiple USB devices were found; provide device_udid in start_session config")
    return devices[0]


class DeviceRuntime:
    """Own one userspace tunnel/RSD and persistent per-provider DVT connections."""

    def __init__(self, requested_udid: str | None = None) -> None:
        self.requested_udid = requested_udid
        self.device_ref: str | None = None
        self.rsd: Any = None
        self.lockdown: Any = None
        self._dvt_by_name: dict[str, Any] = {}
        self._dvt_lock = asyncio.Lock()
        self._stack: AsyncExitStack | None = None

    async def open(self) -> None:
        if self._stack is not None:
            return
        logger = logging.getLogger("performance_helper.tunnel")
        started = time.monotonic()
        logger.info("USB device selection begin")
        device = await select_single_usb_device(self.requested_udid)
        logger.info("USB device selected; userspace RSD setup begin")
        stack = AsyncExitStack()
        try:
            tunnel = UserspaceRsdTunnel(
                serial=device.serial,
                autopair=False,
                remotepairing_fallback=False,
            )
            self.rsd = await stack.enter_async_context(tunnel)
            self.lockdown = await create_using_usbmux(
                serial=device.serial,
                autopair=False,
                connection_type="USB",
            )
            stack.push_async_callback(self.lockdown.close)
        except BaseException:
            await stack.aclose()
            self.rsd = self.lockdown = None
            raise
        self.device_ref = private_device_ref(device.serial)
        self._stack = stack
        logger.info("userspace RSD setup end elapsed_ms=%d", round((time.monotonic() - started) * 1000))

    def device_summary(self) -> dict[str, Any]:
        if self._stack is None or self.device_ref is None:
            raise RuntimeError("device runtime is not open")
        all_values = getattr(self.lockdown, "all_values", {}) or {}
        return {
            "device_ref": self.device_ref,
            "connection_type": "USB",
            "product_type": getattr(self.lockdown, "product_type", None),
            "product_version": getattr(self.lockdown, "product_version", None),
            "build_version": all_values.get("BuildVersion"),
            "developer_transport": "userspace_rsd",
            "dvt_connection_policy": "persistent_per_provider",
            "autopair": False,
            "raw_identifier_emitted": False,
        }

    async def dvt_for(self, provider_name: str) -> Any:
        if self._stack is None or self.rsd is None:
            raise RuntimeError("device runtime is not open")
        async with self._dvt_lock:
            existing = self._dvt_by_name.get(provider_name)
            if existing is not None:
                return existing
            logger = logging.getLogger("performance_helper.tunnel")
            started = time.monotonic()
            logger.info("DVT connection begin provider=%s", provider_name)
            dvt = await self._stack.enter_async_context(DvtProvider(self.rsd))
            self._dvt_by_name[provider_name] = dvt
            logger.info(
                "DVT connection end provider=%s elapsed_ms=%d",
                provider_name,
                round((time.monotonic() - started) * 1000),
            )
            return dvt

    async def close(self) -> None:
        logger = logging.getLogger("performance_helper.tunnel")
        logger.info("runtime cleanup begin")
        stack, self._stack = self._stack, None
        self.rsd = self.lockdown = None
        self._dvt_by_name = {}
        if stack is not None:
            await stack.aclose()
        logger.info("runtime cleanup end")


class FixtureRuntime:
    """Explicit test-only runtime. It never touches usbmux or an iPhone."""

    lockdown = None

    def __init__(self, requested_udid: str | None = None) -> None:
        self.requested_udid = requested_udid
        self.opened = False

    async def open(self) -> None:
        self.opened = True

    def device_summary(self) -> dict[str, Any]:
        return {
            "device_ref": "fixture-device",
            "connection_type": "fixture",
            "is_fixture": True,
            "raw_identifier_emitted": False,
        }

    async def dvt_for(self, provider_name: str) -> Any:
        return None

    async def close(self) -> None:
        self.opened = False
