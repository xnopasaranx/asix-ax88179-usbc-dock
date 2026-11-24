# Steam Deck ASIX AX88179B USB-C Dock Ethernet Driver

Vendor DKMS driver + SteamOS persistence for the ASIX AX88179B USB-to-Ethernet chip found in many USB-C docks used with the Steam Deck.

The mainline Linux `ax88179_178a` driver binds to this chip but stays in `NO-CARRIER` state. This repo uses the official ASIX vendor driver (`ax_usb_nic`) and makes it survive Steam Deck reboots and OS updates.

## What is installed

- `asix-ax88179-dkms` — official ASIX driver v4.2.0 built as a DKMS module.
- `asix-ax88179-ensure.service` — runs at boot and after hot-plug.
- Udev rule — triggers the service when the dock is plugged/unplugged.
- `asix-ax88179.conf` — blacklists the broken mainline `ax88179_178a`.
- Atomic-update keep list — preserves the configuration files across SteamOS updates.
- Cached `.pkg.tar.zst` package — used to rebuild the driver after a SteamOS update wipes `/usr`.

## Hardware tested

- ASIX AX88179B (`0b95:1790`) inside a USB-C dock connected to a Steam Deck.
- Kernel: `6.16.12-valve24.5-1-neptune-616`.

Other AX88179B-based docks/hubs should work as long as the USB IDs stay `0b95:1790`.

## Quick install

On the Steam Deck, connected to the dock:

```bash
git clone https://github.com/YOUR_USERNAME/steamdeck-ax88179b-dock.git
cd steamdeck-ax88179b-dock
sudo bash install.sh
```

The script will:

1. Disable SteamOS readonly mode.
2. Install build dependencies (`base-devel`, `dkms`, matching `linux-neptune-XXX-headers`).
3. Build the AUR package from `PKGBUILD` and install it with `pacman -U`.
4. Copy the persistence files into `/etc` and `/var/lib/`.
5. Cache the built package for post-update rebuilds.
6. Re-enable readonly mode.
7. Switch the adapter to vendor mode immediately.

## Uninstall / revert to CDC-NCM

```bash
cd steamdeck-ax88179b-dock
sudo bash install.sh --uninstall
```

This removes the package, DKMS module, persistence files, cached package, and switches the adapter back to the default `cdc_ncm` driver so your network keeps working.

## Verify

```bash
ip -brief addr show
lsmod | grep ax_usb_nic
cat /sys/bus/usb/devices/*/bConfigurationValue 2>/dev/null | head -n1   # should be 1
```

Expected interface name after switching is something like `enp4s0f3u1u3` (the trailing `c2` from `cdc_ncm` disappears).

## How it survives updates

SteamOS replaces the read-only root filesystem (`/usr`, `/usr/src`, `/lib/modules/...`) on every OS update, wiping the installed driver.

This setup keeps what it needs in persistent locations:

- `/var/lib/asix-ax88179/` — cached package.
- `/var/lib/dkms/` — DKMS registry (lives on the persistent `/var` partition).

After an update, the boot service waits for the network to come up (the Deck will be on `cdc_ncm` fallback until then), then:

1. Disables readonly mode.
2. Installs build tools and the matching kernel headers package from SteamOS repos.
3. Re-installs the cached package into `/usr/src`.
4. Builds and installs the DKMS module for the new kernel.
5. Switches the adapter to vendor config #1.
6. Re-enables readonly mode.

If the rebuild cannot happen (e.g. no internet to fetch new headers), the script falls back to `cdc_ncm` config #2 so the Deck still has working Ethernet.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-shot installer |
| `PKGBUILD` | AUR-style package definition for the ASIX driver |
| `dkms.conf` | DKMS metadata used by the package |
| `modprobe.conf` | Original AUR blacklist (not installed by default; kept as reference) |
| `0002-Complete-TX-NAPI-on-early-exit.patch` | Patch applied during package build |
| `ASIX_USB_NIC_Linux_Driver_Source_v4.2.0.tar.bz2` | Official ASIX driver source tarball |
| `asix-ax88179-ensure.sh` | Boot/replug recovery script |
| `asix-ax88179-ensure.service` | systemd unit that runs the script |
| `99-asix-ax88179.rules` | Udev rule for hot-plug |
| `asix-ax88179.conf` | Modprobe blacklist for mainline `ax88179_178a` |
| `atomic-update-keep.conf` | SteamOS atomic-update keep list |

## Caveats

- I only blacklisted the mainline `ax88179_178a` driver. `cdc_ncm` is kept available as a fallback. If you want to force vendor mode even when the rebuild fails, uncomment the additional `blacklist` lines in `asix-ax88179.conf`.
- A real OS kernel update needs internet to download the matching `linux-neptune-XXX-headers` package. If offline, the deck stays on `cdc_ncm` fallback.
- Building on the Deck takes a couple of minutes the first time. After an OS update the rebuild is also a one-time operation.

## License / credits

- The `PKGBUILD` and packaging files are from the AUR package `asix-ax88179-dkms` (GPL-2.0-or-later).
- The driver source is from ASIX Electronics Corporation.
- The ensure scripts and systemd wiring are my own additions for SteamOS persistence.
