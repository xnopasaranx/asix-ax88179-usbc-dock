#!/bin/bash
set -e

LOG=/var/log/asix-ax88179-ensure.log
mkdir -p /var/log
exec >> "$LOG" 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') ensure started"

# Find ASIX AX88179B device
DEV=""
for d in /sys/bus/usb/devices/*/; do
  if [ -f "$d/idVendor" ] && grep -qx "0b95" "$d/idVendor" && [ -f "$d/idProduct" ] && grep -qx "1790" "$d/idProduct"; then
    DEV="$d"
    break
  fi
done

if [ -z "$DEV" ]; then
  echo "No ASIX AX88179B device present, exiting"
  exit 0
fi

echo "Device found at $DEV"

# Ensure vendor DKMS module exists for this kernel
KVER=$(uname -r)
MODULE_FILE="/lib/modules/$KVER/updates/dkms/ax_usb_nic.ko.zst"
if [ ! -f "$MODULE_FILE" ] && [ ! -f "/lib/modules/$KVER/updates/dkms/ax_usb_nic.ko" ]; then
  echo "Module missing for kernel $KVER, rebuilding..."
  steamos-readonly disable
  # Install build tools and matching headers
  KERNEL_SUFFIX=$(uname -r | sed -n 's/.*neptune-\([0-9]*\).*/\1/p')
  if [ -z "$KERNEL_SUFFIX" ]; then
    echo "Could not determine kernel suffix, trying generic linux-neptune-headers"
    pacman -Syu --noconfirm dkms linux-neptune-headers base-devel || true
  else
    pacman -Syu --noconfirm dkms "linux-neptune-${KERNEL_SUFFIX}-headers" base-devel || true
  fi
  # Reinstall driver source from cached package
  PKG=$(ls /var/lib/asix-ax88179/asix-ax88179-dkms-*.pkg.tar.zst 2>/dev/null | head -n1)
  if [ -f "$PKG" ]; then
    echo "Reinstalling package $PKG"
    pacman -U --noconfirm "$PKG"
  else
    echo "Cached package not found!"
  fi
  # Build/install the module
  if dkms status asix-ax88179/4.2.0 | grep -q "$KVER"; then
    # DKMS thinks it is installed but rootfs module path was wiped; force copy
    echo "DKMS status already shows $KVER, forcing install"
    dkms install --force asix-ax88179/4.2.0 -k "$KVER" || true
  else
    dkms build asix-ax88179/4.2.0 -k "$KVER" && dkms install asix-ax88179/4.2.0 -k "$KVER" || true
  fi
  steamos-readonly enable
  if [ ! -f "$MODULE_FILE" ] && [ ! -f "/lib/modules/$KVER/updates/dkms/ax_usb_nic.ko" ]; then
    echo "Module still missing after rebuild"
  fi
fi

# Switch adapter to vendor config #1 if not already
cur=$(cat "$DEV/bConfigurationValue")
if [ "$cur" != "1" ]; then
  echo "Switching configuration from $cur to 1"
  # Unbind class drivers before switching
  for iface in "$DEV"*:*; do
    [ -L "$iface/driver" ] || continue
    drv=$(basename "$(readlink -f "$iface/driver")" 2>/dev/null || true)
    if [ "$drv" = "cdc_ncm" ] || [ "$drv" = "cdc_ether" ]; then
      echo "Unbinding $(basename "$iface") from $drv"
      echo "$(basename "$iface")" > "/sys/bus/usb/drivers/$drv/unbind" 2>/dev/null || true
    fi
  done
  echo 1 > "$DEV/bConfigurationValue"
  sleep 5
fi

# Load the vendor module
modprobe ax_usb_nic

# Wait briefly for a carrier
success=0
for i in $(seq 1 20); do
  sleep 1
  for iface in /sys/class/net/*/; do
    drv=$(basename "$(readlink -f "$iface/device/driver" 2>/dev/null)" 2>/dev/null || true)
    name=$(basename "$iface")
    if [ "$drv" = "ax_usb_nic" ]; then
      carrier=$(cat "$iface/carrier" 2>/dev/null || echo 0)
      if [ "$carrier" = "1" ]; then
        echo "Interface $name is up with ax_usb_nic (carrier=$carrier)"
        success=1
        break 2
      fi
    fi
  done
done

if [ "$success" = "1" ]; then
  echo "Vendor mode active"
  exit 0
fi

# Fallback to CDC-NCM so we keep network connectivity
echo "Vendor mode failed to come up, falling back to cdc_ncm config 2"
for iface in "$DEV"*:*; do
  [ -L "$iface/driver" ] || continue
  drv=$(basename "$(readlink -f "$iface/driver")" 2>/dev/null || true)
  if [ "$drv" = "ax_usb_nic" ] && [ -e "/sys/bus/usb/drivers/ax_usb_nic/$(basename "$iface")" ]; then
    echo "$(basename "$iface")" > /sys/bus/usb/drivers/ax_usb_nic/unbind 2>/dev/null || true
  fi
done
echo 2 > "$DEV/bConfigurationValue"
sleep 5
modprobe cdc_ncm
echo "Fallback to cdc_ncm done"
exit 0

