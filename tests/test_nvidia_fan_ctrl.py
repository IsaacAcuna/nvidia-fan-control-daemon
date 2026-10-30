"""Tests for nvidia-fan-ctrl. NVML is replaced with a mock, so no GPU or root is needed.

Run from the repo root: python3 -m unittest discover tests
"""

import ctypes
import importlib.machinery
import importlib.util
import io
import os
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "nvidia-fan-ctrl"


def load_daemon():
    """Import the script as a module with a mocked libnvidia-ml."""
    loader = importlib.machinery.SourceFileLoader("nvidia_fan_ctrl", str(SCRIPT))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    with mock.patch("ctypes.CDLL"):
        loader.exec_module(module)
    module.nvml.nvmlErrorString.return_value = b"mock error"
    return module


def fake_gpu(daemon, lo=23, hi=100, fans=1):
    """A Gpu with its NVML setup skipped."""
    gpu = object.__new__(daemon.Gpu)
    gpu.uuid = gpu.name = "GPU-test"
    gpu.dev = ctypes.c_void_p()
    gpu.fans, gpu.lo, gpu.hi = fans, lo, hi
    gpu.current = None
    gpu.failsafe = False
    return gpu


def report_temp(daemon, temp):
    """Make nvmlDeviceGetTemperature succeed with temp, or fail if temp is None."""
    def get_temperature(dev, sensor, ref):
        if temp is None:
            return 1
        ref._obj.value = temp
        return 0
    daemon.nvml.nvmlDeviceGetTemperature.side_effect = get_temperature


class CurveTest(unittest.TestCase):
    def setUp(self):
        self.daemon = load_daemon()

    def test_below_first_point_uses_first_speed(self):
        self.assertEqual(self.daemon.curve(0), 30)
        self.assertEqual(self.daemon.curve(40), 30)

    def test_on_points(self):
        for temp, speed in self.daemon.CURVE:
            self.assertEqual(self.daemon.curve(temp), speed)

    def test_interpolates_between_points(self):
        self.assertEqual(self.daemon.curve(45), 64)
        self.assertEqual(self.daemon.curve(55), 80)

    def test_above_last_point_uses_last_speed(self):
        self.assertEqual(self.daemon.curve(95), 100)

    def test_never_decreases(self):
        speeds = [self.daemon.curve(t) for t in range(0, 101)]
        self.assertEqual(speeds, sorted(speeds))


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.daemon = load_daemon()
        self.daemon.nvml.nvmlDeviceSetFanSpeed_v2.return_value = 0
        self.gpu = fake_gpu(self.daemon)

    def step(self, temp):
        report_temp(self.daemon, temp)
        with redirect_stdout(io.StringIO()) as out:
            self.gpu.update()
        return out.getvalue()

    def test_speeds_up_immediately(self):
        self.step(40)
        self.step(50)
        self.assertEqual(self.gpu.current, 75)

    def test_small_drop_keeps_speed(self):
        self.step(60)
        self.step(58)
        self.assertEqual(self.gpu.current, 85)

    def test_drop_past_hysteresis_slows_down(self):
        self.step(60)
        self.step(50)
        self.assertEqual(self.gpu.current, self.daemon.curve(50 + self.daemon.HYSTERESIS_C))

    def test_unchanged_speed_is_not_resent(self):
        self.step(35)
        self.step(36)
        self.assertEqual(self.daemon.nvml.nvmlDeviceSetFanSpeed_v2.call_count, 1)

    def test_read_failure_uses_failsafe_and_logs_once(self):
        first = self.step(None)
        second = self.step(None)
        self.assertEqual(self.gpu.current, self.daemon.FAILSAFE_SPEED)
        self.assertIn("failsafe", first)
        self.assertEqual(second, "")
        self.assertIn("readable again", self.step(40))

    def test_speed_changes_logged_only_in_debug(self):
        self.assertEqual(self.step(45), "")
        self.daemon.debug = True
        self.assertIn("temp 55C", self.step(55))

    def test_set_speed_clamps_to_card_range(self):
        gpu = fake_gpu(self.daemon, lo=40, hi=90, fans=2)
        self.assertEqual(gpu.set_speed(30), 40)
        self.assertEqual(gpu.set_speed(100), 90)
        self.assertEqual(self.daemon.nvml.nvmlDeviceSetFanSpeed_v2.call_count, 4)

    def test_set_speed_error_raises(self):
        self.daemon.nvml.nvmlDeviceSetFanSpeed_v2.return_value = 4
        with self.assertRaisesRegex(RuntimeError, "set fan 0"):
            self.gpu.set_speed(50)


class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.daemon = load_daemon()

    def run_main(self, uuids):
        with mock.patch.dict(os.environ, {"GPU_UUIDS": uuids}), \
             mock.patch("sys.argv", ["nvidia-fan-ctrl"]), \
             redirect_stderr(io.StringIO()) as err, \
             self.assertRaises(SystemExit) as exit:
            self.daemon.main()
        return exit.exception.code, err.getvalue()

    def test_refuses_to_start_without_uuids(self):
        for value in ("", "   ", ","):
            code, err = self.run_main(value)
            self.assertEqual(code, self.daemon.EX_CONFIG)
            self.assertIn("GPU_UUIDS is not set", err)
        self.daemon.nvml.nvmlInit_v2.assert_not_called()

    def test_refuses_to_start_with_unknown_uuid(self):
        self.daemon.nvml.nvmlInit_v2.return_value = 0
        self.daemon.nvml.nvmlDeviceGetHandleByUUID.return_value = 6  # NVML_ERROR_NOT_FOUND
        code, err = self.run_main("GPU-bogus")
        self.assertEqual(code, self.daemon.EX_CONFIG)
        self.assertIn("No GPU with UUID GPU-bogus", err)


if __name__ == "__main__":
    unittest.main()
