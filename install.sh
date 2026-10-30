#!/bin/bash
# Installer for nvidia-fan-control-daemon.
#
#   wget -qO- https://raw.githubusercontent.com/IsaacAcuna/nvidia-fan-control-daemon/main/install.sh | sudo bash
#
# Options (environment variables):
#   GPU_UUIDS="GPU-... GPU-..."  skip the prompt and control these GPUs
#   REF=<branch or tag>          download this version instead of main
#
# Run from a clone of the repo, it installs that clone's files instead of downloading.

# Everything is inside main() so a partially downloaded script never runs.
main() {
    set -euo pipefail

    local repo="IsaacAcuna/nvidia-fan-control-daemon"
    local ref="${REF:-main}"
    local conf=/etc/default/nvidia-fan-ctrl

    die() { echo "Error: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    ((EUID == 0)) || die "run as root, e.g. wget -qO- https://raw.githubusercontent.com/$repo/main/install.sh | sudo bash"
    command -v systemctl >/dev/null || die "systemd is required"
    command -v python3 >/dev/null || die "python3 is required"

    # --- Detect GPUs ---------------------------------------------------------
    # sysfs lists every NVIDIA card on the PCI bus (vendor 0x10de, class VGA or
    # 3D controller); nvidia-smi only the ones the driver can use.
    local -A pci_names=()
    local bus dev id
    for dev in /sys/bus/pci/devices/*; do
        [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/class") == 0x030[02]* ]] || continue
        id=$(<"$dev/device")
        pci_names[${dev##*/}]="NVIDIA GPU [10de:${id#0x}]"
    done
    ((${#pci_names[@]})) || die "no NVIDIA GPUs detected in this system, nothing to install"

    if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L >/dev/null 2>&1; then
        echo "Found NVIDIA GPU(s), but the NVIDIA driver isn't installed, isn't loaded or can't use them:" >&2
        for bus in "${!pci_names[@]}"; do echo "  $bus ${pci_names[$bus]}" >&2; done
        die "the NVIDIA proprietary driver (520 or newer) is required"
    fi

    local driver
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    ((${driver%%.*} >= 520)) || die "NVIDIA driver $driver is too old, 520 or newer is required"

    local -a names=() uuids=()
    local name uuid bus
    while IFS=', ' read -r uuid bus name; do
        names+=("$name")
        uuids+=("$uuid")
        bus=${bus,,}
        unset "pci_names[${bus: -12}]"  # nvidia-smi pads the PCI domain to 8 digits
    done < <(nvidia-smi --query-gpu=uuid,pci.bus_id,name --format=csv,noheader)

    if ((${#pci_names[@]})); then
        echo "Warning: these NVIDIA GPUs aren't usable by the installed driver (unsupported"
        echo "by this driver version, bound to another driver, or disabled) and can't be controlled:"
        for bus in "${!pci_names[@]}"; do echo "  $bus ${pci_names[$bus]}"; done
        echo
    fi

    # --- Choose GPUs ---------------------------------------------------------
    local selected="${GPU_UUIDS:-}"
    if [[ -n $selected ]]; then
        selected=${selected//,/ }
        for uuid in $selected; do
            [[ " ${uuids[*]} " == *" $uuid "* ]] || die "GPU_UUIDS: no GPU with UUID $uuid (see nvidia-smi -L)"
        done
    else
        { : </dev/tty; } 2>/dev/null || die "no terminal to prompt on; set GPU_UUIDS to the UUIDs from nvidia-smi -L"
        echo "NVIDIA GPUs (driver $driver):"
        local i
        for i in "${!uuids[@]}"; do echo "  $((i + 1))) ${names[$i]}  ${uuids[$i]}"; done
        local answer n
        while :; do
            read -rp "GPUs to control (numbers separated by spaces, or 'a' for all): " answer </dev/tty
            selected=""
            [[ $answer == [aA] ]] && answer=$(seq -s ' ' 1 "${#uuids[@]}")
            for n in $answer; do
                [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#uuids[@]})) || { selected=""; break; }
                selected+="${uuids[$((n - 1))]} "
            done
            [[ -n $selected ]] && break
            echo "Please enter numbers from 1 to ${#uuids[@]}."
        done
        selected=${selected% }
    fi

    # --- Get the files -------------------------------------------------------
    local src="" here
    here=$(dirname -- "${BASH_SOURCE[0]:-}" 2>/dev/null) || true
    if [[ -f ${BASH_SOURCE[0]:-} && -f $here/nvidia-fan-ctrl && -f $here/nvidia-fan-ctrl.service ]]; then
        src=$(cd -- "$here" && pwd)
        info "Installing from $src"
    else
        local url="https://github.com/$repo/archive/$ref.tar.gz"
        tmp=$(mktemp -d)  # global so the EXIT trap can still see it
        trap 'rm -rf "$tmp"' EXIT
        info "Downloading $url"
        if command -v curl >/dev/null; then
            curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components=1
        elif command -v wget >/dev/null; then
            wget -qO- "$url" | tar -xz -C "$tmp" --strip-components=1
        else
            die "curl or wget is required"
        fi
        src=$tmp
    fi

    # --- Install -------------------------------------------------------------
    info "Installing daemon and service"
    install -m 755 "$src/nvidia-fan-ctrl" /usr/local/sbin/nvidia-fan-ctrl
    install -m 644 "$src/nvidia-fan-ctrl.service" /etc/systemd/system/nvidia-fan-ctrl.service

    if [[ -f $conf ]]; then
        info "Updating GPU_UUIDS in existing $conf (other settings kept)"
        if grep -q '^GPU_UUIDS=' "$conf"; then
            sed -i "s/^GPU_UUIDS=.*/GPU_UUIDS=\"$selected\"/" "$conf"
        else
            echo "GPU_UUIDS=\"$selected\"" >>"$conf"
        fi
    else
        info "Writing $conf"
        install -m 644 "$src/nvidia-fan-ctrl.conf" "$conf"
        sed -i "s/^GPU_UUIDS=.*/GPU_UUIDS=\"$selected\"/" "$conf"
    fi

    systemctl daemon-reload
    systemctl enable nvidia-fan-ctrl >/dev/null 2>&1
    systemctl restart nvidia-fan-ctrl
    sleep 2
    if systemctl is-active --quiet nvidia-fan-ctrl; then
        info "Done. nvidia-fan-ctrl is running and will start at boot."
        echo "    Log:    journalctl -u nvidia-fan-ctrl -f"
        echo "    Config: $conf"
    else
        journalctl -u nvidia-fan-ctrl -n 10 --no-pager -o cat >&2 || true
        die "the service failed to start, see the log above"
    fi
}

main "$@"
