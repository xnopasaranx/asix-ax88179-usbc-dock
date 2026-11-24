#!/bin/bash
# Install or uninstall the ASIX AX88179B vendor driver and persistence scripts on SteamOS.
#
# Install (default):
#   sudo bash install.sh
#
# Uninstall / revert:
#   sudo bash install.sh --uninstall

set -e

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root. Try: sudo bash install.sh"
  exit 1
fi

if [ -z "$SUDO_USER" ]; then
  echo "ERROR: Please run this script through sudo from a normal user account."
  echo "Example: sudo bash install.sh"
  exit 1
fi

BUILD_USER="$SUDO_USER"
REPO_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

case "${1:-install}" in
  --uninstall|uninstall|remove)
    DO_UNINSTALL=1
    ;;
  --install|install|"")
    DO_UNINSTALL=0
    ;;
  *)
    echo "Usage: sudo bash install.sh [--uninstall]"
    exit 1
    ;;
esac

find_asix_device() {
  for d in /sys/bus/usb/devices/*/; do
    if [ -f "$d/idVendor" ] && grep -qx "0b95" "$d/idVendor" && [ -f "$d/idProduct" ] && grep -qx "1790" "$d/idProduct"; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

do_uninstall() {
  echo "=== Reverting ASIX AX88179B vendor driver changes ==="
  echo "Build user: $BUILD_USER"

  steamos-readonly disable

  # Stop/disable the persistent service
  systemctl stop asix-ax88179-ensure.service 2>/dev/null || true
  systemctl disable asix-ax88179-ensure.service 2>/dev/null || true

  # Remove persistence files
  rm -f /etc/systemd/system/asix-ax88179-ensure.service
  rm -f /etc/udev/rules.d/99-asix-ax88179.rules
  rm -f /etc/modprobe.d/asix-ax88179.conf
  rm -f /etc/atomic-update.conf.d/99-asix-ax88179.conf
  rm -rf /etc/asix-ax88179

  # Remove package cache
  rm -rf /var/lib/asix-ax88179

  # Remove legacy user-path files from earlier versions of this installer
  rm -f "/home/$BUILD_USER/.local/bin/asix-ax88179-ensure.sh"
  rm -rf "/home/$BUILD_USER/.local/share/asix-ax88179"

  # Remove DKMS source and module
  rm -rf /usr/src/asix-ax88179-*
  dkms remove asix-ax88179/4.2.0 --all 2>/dev/null || true

  # Uninstall the package
  pacman -R --noconfirm asix-ax88179-dkms 2>/dev/null || true

  # Switch the adapter back to CDC-NCM config #2 if present
  DEV="$(find_asix_device)"
  if [ -n "$DEV" ]; then
    echo "Switching $(basename "$DEV") back to CDC-NCM config 2..."
    for iface in "$DEV"*:*; do
      [ -L "$iface/driver" ] || continue
      drv="$(basename "$(readlink -f "$iface/driver")" 2>/dev/null || true)"
      if [ "$drv" = "ax_usb_nic" ] && [ -e "/sys/bus/usb/drivers/ax_usb_nic/$(basename "$iface")" ]; then
        echo "$(basename "$iface")" > /sys/bus/usb/drivers/ax_usb_nic/unbind 2>/dev/null || true
      fi
    done
    rmmod ax_usb_nic 2>/dev/null || true
    echo 2 > "$DEV/bConfigurationValue"
    sleep 3
    modprobe cdc_ncm
  else
    echo "No ASIX AX88179B device currently attached."
  fi

  depmod -a
  systemctl daemon-reload
  udevadm control --reload-rules

  steamos-readonly enable

  echo
  echo "Uninstall complete. The adapter is back on the CDC-NCM driver (config 2)."
}

do_install() {
  echo "=== ASIX AX88179B vendor driver installer for Steam Deck ==="
  echo "Build user: $BUILD_USER"
  echo "Repo dir:   $REPO_DIR"

  KVER=$(uname -r)
  KERNEL_SUFFIX=$(echo "$KVER" | sed -n 's/.*neptune-\([0-9]*\).*/\1/p')
  if [ -z "$KERNEL_SUFFIX" ]; then
    echo "ERROR: Could not determine SteamOS kernel suffix from uname -r: $KVER"
    exit 1
  fi
  HEADERS_PKG="linux-neptune-${KERNEL_SUFFIX}-headers"

  echo "Kernel: $KVER  -> headers package: $HEADERS_PKG"

  steamos-readonly disable

  # Install build dependencies
  pacman -Syu --noconfirm base-devel dkms "$HEADERS_PKG"

  # Build the package as the normal user (makepkg refuses to run as root)
  cd "$REPO_DIR"
  echo "Building package as user '$BUILD_USER'..."
  su "$BUILD_USER" -c "makepkg --noconfirm"

  # Install the built package
  PKG="$(ls "$REPO_DIR"/asix-ax88179-dkms-*.pkg.tar.zst | head -n1)"
  echo "Installing $PKG"
  pacman -U --noconfirm "$PKG"

  # Install persistence scripts into system locations (user-agnostic)
  echo "Installing persistence files..."
  install -Dm755 "$REPO_DIR/asix-ax88179-ensure.sh" /etc/asix-ax88179/asix-ax88179-ensure.sh
  install -Dm644 "$REPO_DIR/asix-ax88179-ensure.service" /etc/systemd/system/asix-ax88179-ensure.service
  install -Dm644 "$REPO_DIR/99-asix-ax88179.rules" /etc/udev/rules.d/99-asix-ax88179.rules
  install -Dm644 "$REPO_DIR/asix-ax88179.conf" /etc/modprobe.d/asix-ax88179.conf
  install -Dm644 "$REPO_DIR/atomic-update-keep.conf" /etc/atomic-update.conf.d/99-asix-ax88179.conf

  # Cache the package for rebuilds after SteamOS updates
  CACHE_DIR="/var/lib/asix-ax88179"
  mkdir -p "$CACHE_DIR"
  cp "$PKG" "$CACHE_DIR/"
  chmod -R a+r "$CACHE_DIR"

  depmod -a
  systemctl daemon-reload
  udevadm control --reload-rules
  systemctl enable asix-ax88179-ensure.service

  steamos-readonly enable

  # Force vendor mode now
  /etc/asix-ax88179/asix-ax88179-ensure.sh

  echo
  ip -brief addr show | grep -E 'enp.*ax_usb_nic|enp' || true
  lsmod | grep ax_usb_nic && echo "Vendor driver (ax_usb_nic) is loaded." || echo "Vendor driver not loaded; check /var/log/asix-ax88179-ensure.log"
}

if [ "$DO_UNINSTALL" = "1" ]; then
  do_uninstall
else
  do_install
fi
