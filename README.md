# nvidia-fan-control-daemon

A systemd daemon that applies a custom fan curve to NVIDIA GPUs. It talks to
the driver directly through NVML (`libnvidia-ml.so.1`), so it needs no X/Wayland
session, no Coolbits and no `nvidia-settings`, and it works from boot before
anyone logs in.

- Linear-interpolated fan curve, with hysteresis so the fan doesn't hunt
- Failsafe to 100% if the temperature can't be read
- Hands the fans back to the driver's automatic control when stopped
- Controls only the cards you list by UUID, so multi-GPU systems are handled safely

## Prerequisites

| Requirement | Notes | Check with |
| --- | --- | --- |
| Linux with systemd | Runs as a system service | `systemctl --version` |
| NVIDIA proprietary driver, **520 or newer** | Earlier drivers lack the NVML fan control calls. Nouveau is not supported. | `nvidia-smi` (top right shows the driver version) |
| NVML library | Installed with the driver (`libnvidia-ml1` on Debian/Ubuntu) | `ldconfig -p \| grep libnvidia-ml.so.1` |
| Python 3.6+ | Standard library only, no pip packages | `python3 --version` |
| Root access | Setting fan speed through NVML requires root | |

Recommended: `nvidia-persistenced` running (`systemctl status nvidia-persistenced`).
It keeps the driver loaded when no display is using the GPU. The service file
asks for it but starts fine without it.

## Installation

1. Clone the repo:

   ```sh
   git clone https://github.com/IsaacAcuna/nvidia-fan-control-daemon.git
   cd nvidia-fan-control-daemon
   ```

2. Find the UUIDs of the GPUs you want to control:

   ```sh
   nvidia-smi -L
   ```

   ```
   GPU 0: NVIDIA GeForce RTX 3080 (UUID: GPU-11111111-2222-3333-4444-555555555555)
   GPU 1: NVIDIA GeForce GTX 1080 (UUID: GPU-66666666-7777-8888-9999-000000000000)
   ```

3. Install the config file and put your UUIDs in `GPU_UUIDS`, separated by spaces:

   ```sh
   sudo install -m 644 nvidia-fan-ctrl.conf /etc/default/nvidia-fan-ctrl
   sudoedit /etc/default/nvidia-fan-ctrl
   ```

   ```sh
   GPU_UUIDS="GPU-11111111-2222-3333-4444-555555555555"
   ```

   The service refuses to start until at least one UUID is set. Every listed
   GPU gets the same fan curve; to change the curve see [Configuration](#configuration).

4. Stop anything else that controls the fan, or the two will fight. That includes
   older `nvidia-settings` fan scripts, GreenWithEnvy, CoolerControl, or a manual
   `GPUFanControlState=1` setting.

5. Install and start the service:

   ```sh
   sudo install -m 755 nvidia-fan-ctrl /usr/local/sbin/nvidia-fan-ctrl
   sudo install -m 644 nvidia-fan-ctrl.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now nvidia-fan-ctrl
   ```

6. Check that it is working:

   ```sh
   systemctl status nvidia-fan-ctrl
   journalctl -u nvidia-fan-ctrl -n 20
   ```

   You should see something like:

   ```
   NVIDIA GeForce RTX 3080: controlling 2 fan(s), range 30-100%
   NVIDIA GeForce RTX 3080: temp 39C -> fan 30%
   ```

   Compare with `nvidia-smi --query-gpu=temperature.gpu,fan.speed --format=csv`.

## Configuration

Which GPUs to control is set in `/etc/default/nvidia-fan-ctrl`:

| Setting | Meaning |
| --- | --- |
| `GPU_UUIDS` | Space-separated UUIDs of the GPUs to control (from `nvidia-smi -L`). Required. |

After changing it, run `sudo systemctl restart nvidia-fan-ctrl`.

The fan curve and timing are in the `USER VARIABLES` block at the top of
`nvidia-fan-ctrl`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `POLL_SECONDS` | `2` | How often the temperature is checked |
| `HYSTERESIS_C` | `3` | The fan speeds up immediately but only slows down once the temperature has dropped this many °C |
| `FAILSAFE_SPEED` | `100` | Fan % used if the temperature can't be read |
| `CURVE` | see below | `(temperature °C, fan %)` points |

The default curve:

| Temp (°C) | ≤40 | 41 | 45 | 50 | 55 | 60 | 70 | ≥80 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fan (%) | 30 | 55 | 64 | 75 | 80 | 85 | 95 | 100 |

Speeds between points are interpolated linearly. Below the first point the
first speed is used, and above the last point the last speed is used. Points
must be in increasing temperature order. Any speed outside the card's supported
range (printed at startup, e.g. `23-100%`) is clamped to it.

To apply changes, reinstall the script and restart the service:

```sh
sudo install -m 755 nvidia-fan-ctrl /usr/local/sbin/nvidia-fan-ctrl
sudo systemctl restart nvidia-fan-ctrl
```

The service runs the copy in `/usr/local/sbin`, so editing the repo alone does
nothing until you reinstall.

## Usage

| Task | Command |
| --- | --- |
| Follow the live log | `journalctl -u nvidia-fan-ctrl -f` |
| Stop temporarily (fans go back to automatic) | `sudo systemctl stop nvidia-fan-ctrl` |
| Start again | `sudo systemctl start nvidia-fan-ctrl` |
| Disable at boot | `sudo systemctl disable --now nvidia-fan-ctrl` |

The service restarts automatically after 5 seconds if it crashes.

## Uninstall

```sh
sudo systemctl disable --now nvidia-fan-ctrl
sudo rm /usr/local/sbin/nvidia-fan-ctrl /etc/systemd/system/nvidia-fan-ctrl.service \
        /etc/default/nvidia-fan-ctrl
sudo systemctl daemon-reload
```

Stopping the service returns the fans to the driver's automatic control.

## Troubleshooting

- **Service fails with `GPU_UUIDS is not set`**: add at least one UUID to `/etc/default/nvidia-fan-ctrl`, then restart.
- **Service fails with `No GPU with UUID ...`**: that UUID doesn't match any card. Copy it again from `nvidia-smi -L`.
- **Service fails with `Failed to load environment files`**: `/etc/default/nvidia-fan-ctrl` is missing. Install it as in step 3.
- **`set fan 0: Insufficient Permissions`**: the script wasn't run as root. Run it through the service, or with `sudo`.
- **`... Not Supported`, or `AttributeError: ... undefined symbol: nvmlDevice...`**: the card doesn't support software fan control, or the driver is older than 520.
- **`OSError: libnvidia-ml.so.1: cannot open shared object file`**: the NVIDIA driver (or its NVML library) isn't installed.
- **Testing a change without the service**: stop the service, then run `sudo GPU_UUIDS="GPU-..." ./nvidia-fan-ctrl` from the repo and press Ctrl+C to exit.

## License

GPL-3.0, see [LICENSE](LICENSE).
