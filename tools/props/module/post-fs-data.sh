#!/system/bin/sh
# Runs before zygote, so android.os.Build picks up these values.
resetprop ro.build.tags release-keys

# FiiO's firmware leaves ro.serialno empty (Build.SERIAL = "unknown"). Use the Exynos chip ID,
# formatted the way the USB/adb serial already is (e.g. 123ABC456DE -> 00000123abc456de).
id=$(cat /sys/devices/system/chip-id/unique_id 2>/dev/null)
if [ -n "$id" ] && [ -z "$(getprop ro.serialno)" ]; then
  serial=$(printf '%016x' "0x$id")
  resetprop ro.serialno "$serial"
  resetprop ro.boot.serialno "$serial"
fi
