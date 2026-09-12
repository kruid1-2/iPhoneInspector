from __future__ import annotations

import json
import unittest
from pathlib import Path

from pymobiledevice3.services.dvt.instruments.network_monitor import (
    ConnectionDetectionEvent,
    ConnectionUpdateEvent,
)

from performance_helper.providers.battery_provider import normalize_battery
from performance_helper.providers.energy_provider import normalize_energy
from performance_helper.providers.network_provider import NetworkAggregator
from performance_helper.providers.oslog_provider import is_notable_event
from performance_helper.providers.sysmon_provider import configure_output_frequency, normalize_system, select_processes


FIXTURES = Path(__file__).parent / "fixtures"


def load_fixture(name: str):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class ParserTests(unittest.TestCase):
    def test_sysmon_output_frequency_matches_requested_sample_interval(self) -> None:
        class FakeTap:
            _config = {"ur": 1, "sampleInterval": 1_000_000_000}

        tap = FakeTap()
        result = configure_output_frequency(tap, 1_000)
        self.assertTrue(result["applied"])
        self.assertEqual(result["previous_ms"], 1)
        self.assertEqual(tap._config["ur"], 1_000)

    def test_system_preserves_raw_fields_without_unit_guessing(self) -> None:
        result = normalize_system(load_fixture("system.json"))
        self.assertEqual(result["metrics"]["CPU_TotalLoad"]["raw_field"], "CPU_TotalLoad")
        self.assertIsNone(result["metrics"]["CPU_TotalLoad"]["unit"])
        self.assertIn("vmFreeCount", result["metrics"])

    def test_process_selection_keeps_top_and_watchlist(self) -> None:
        selected, summary = select_processes(
            load_fixture("processes.json"), 3, ("SpringBoard", "backboardd")
        )
        names = {item["name"] for item in selected}
        self.assertIn("SpringBoard", names)
        self.assertIn("backboardd", names)
        self.assertIn("DTServiceHub", names)
        self.assertLessEqual(len(selected), 3)
        overhead = next(item for item in selected if item["name"] == "DTServiceHub")
        self.assertTrue(overhead["monitor_overhead"])
        self.assertEqual(summary["process_count"], 4)

    def test_process_memory_is_labeled_bytes_from_library_mapping(self) -> None:
        selected, _ = select_processes(load_fixture("processes.json"), 4, ())
        process = selected[0]
        self.assertEqual(process["metrics"]["physFootprint"]["unit"], "bytes")
        self.assertEqual(
            process["metrics"]["physFootprint"]["display_value"],
            round(process["metrics"]["physFootprint"]["value"] / 1_048_576, 3),
        )

    def test_unavailable_system_cpu_fields_remain_unavailable(self) -> None:
        result = normalize_system({"CPU_SystemLoad": -1, "CPU_UserLoad": -1})
        self.assertEqual(result["metrics"]["CPU_SystemLoad"]["availability"], "unavailable")
        self.assertIsNone(result["metrics"]["CPU_SystemLoad"]["value"])
        self.assertEqual(result["metrics"]["CPU_SystemLoad"]["raw_value"], -1)

    def test_battery_does_not_invent_temperature_or_power_units(self) -> None:
        result = normalize_battery(load_fixture("battery.json"))
        self.assertIsNone(result["metrics"]["Temperature"]["unit"])
        self.assertIsNone(result["metrics"]["InstantAmperage"]["unit"])
        self.assertNotIn("power", result)

    def test_missing_battery_fields_do_not_crash(self) -> None:
        result = normalize_battery({"CurrentCapacity": 50})
        self.assertEqual(result["metrics"]["CurrentCapacity"]["value"], 50)
        self.assertIn("Voltage", result["missing_fields"])

    def test_energy_values_stay_raw(self) -> None:
        result = normalize_energy(load_fixture("energy.json"), [55], {55: "SpringBoard"})
        self.assertIn("55.energy.cost", result["metrics"])
        self.assertIsNone(result["metrics"]["55.energy.cost"]["unit"])

    def test_network_aggregate_drops_addresses_and_negative_pid(self) -> None:
        aggregate = NetworkAggregator()
        aggregate.consume(ConnectionDetectionEvent(None, None, 2, -2, 100, 10, 7, 1))
        aggregate.consume(ConnectionUpdateEvent(5, 500, 3, 300, 0, 0, 0, 0, 0, 7, 1))
        result = aggregate.snapshot_and_reset()
        self.assertFalse(result["process_association_available"])
        self.assertFalse(result["process_attribution_available"])
        self.assertFalse(result["addresses_retained"])
        self.assertNotIn("local_address", result)
        self.assertEqual(result["rx_bytes_delta"], 500)

    def test_network_missing_counter_is_treated_as_no_new_value(self) -> None:
        aggregate = NetworkAggregator()
        aggregate.consume(ConnectionUpdateEvent(None, 500, 3, None, 0, 0, 0, 0, 0, 7, 1))
        aggregate.consume(ConnectionUpdateEvent(10, None, None, 700, 0, 0, 0, 0, 0, 7, 2))
        result = aggregate.snapshot_and_reset()
        self.assertEqual(result["rx_packets_delta"], 10)
        self.assertEqual(result["rx_bytes_delta"], 500)
        self.assertEqual(result["tx_packets_delta"], 3)
        self.assertEqual(result["tx_bytes_delta"], 700)

    def test_context_process_name_alone_does_not_emit_log_event(self) -> None:
        payload = {"level": "Info"}
        self.assertFalse(is_notable_event(payload, ["springboard"]))
        self.assertTrue(is_notable_event(payload, ["watchdog"]))
        self.assertTrue(is_notable_event({"level": "Error"}, []))
