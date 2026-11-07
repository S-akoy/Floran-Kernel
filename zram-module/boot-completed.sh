#!/system/bin/sh
# Force zram0 to LZ4KD with a 16384 MiB (16 GiB) disksize and make the VM
# swap to it as eagerly as the kernel allows (swappiness=200).
#
# The ROM configures zram from /vendor/bin/init.kernel.post_boot.sh (and
# init.qcom.post_boot.sh) at sys.boot_completed=1; those scripts cap the size
# at 6144/4096 MiB and only write comp_algorithm on low-RAM ("Go") devices.
# The zram driver itself comes from the ROM's system_dlkm module, whose
# built-in default is lzo-rle, so neither setting can be changed from the
# kernel Image alone.
#
# KernelSU executes module scripts as `<ksud-busybox> sh boot-completed.sh`.
# Busybox ash runs its own applets (swapon, mkswap, ...) in preference to the
# binaries in PATH, and busybox's swapon has no -p option at all, which made an
# earlier version of this script fail at the swapon step and leave zram0 with a
# valid disksize but no active swap.  Every tool call below therefore uses an
# absolute path to the ROM's toybox, which supports -p.

LOG=/data/local/tmp/zram_lz4kd.log
exec >>"$LOG" 2>&1
echo "=== $(date) zram_lz4kd boot-completed"

TARGET_ALG=lz4kd
TARGET_SIZE=17179869184         # 16384 MiB (16 GiB)
SWAP_PRIO=32758
SWAPPINESS=200                  # kernel maximum on 6.1 (range 0..200)
PAGE_CLUSTER=0                  # 1 page per swap I/O, best for zram
DEV=/dev/block/zram0
SYSFS=/sys/block/zram0
TOOL=/system/bin

# Wait for the device node (ueventd) to show up.
i=0
while [ ! -e "$SYSFS/disksize" ] && [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
done
if [ ! -e "$SYSFS/disksize" ]; then
    echo "ERROR: $SYSFS/disksize not found, giving up"
    exit 1
fi

# init.kernel.post_boot.sh and init.qcom.post_boot.sh both run at
# sys.boot_completed=1; give them time to finish before we take over.
sleep 10

if ! grep -q "name[[:space:]]*:[[:space:]]*$TARGET_ALG" /proc/crypto; then
    echo "ERROR: $TARGET_ALG is not registered in this kernel, keeping current zram"
    exit 1
fi

# Swap eagerness.  The vendor scripts set swappiness=100; push it to the kernel
# maximum so page reclaim goes to zram instead of dropping page cache.  Applied
# on every run, including the "nothing to do" path.
apply_vm_tuning() {
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null || echo "WARN: could not set vm.swappiness"
    echo "$PAGE_CLUSTER" > /proc/sys/vm/page-cluster 2>/dev/null || echo "WARN: could not set vm.page-cluster"
    echo "vm tuning: swappiness=$(cat /proc/sys/vm/swappiness) page-cluster=$(cat /proc/sys/vm/page-cluster)"
}
apply_vm_tuning

prev_alg=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$SYSFS/comp_algorithm")
prev_size=$(cat "$SYSFS/disksize")
echo "current: alg=${prev_alg:-?} size=${prev_size:-0}"

swap_active() {
    grep -q "^$DEV " /proc/swaps
}

# toybox swapon; fall back to the default priority if the kernel rejects it.
swap_on() {
    if "$TOOL/swapon" -p "$SWAP_PRIO" "$DEV"; then
        return 0
    fi
    echo "WARN: swapon -p $SWAP_PRIO failed, retrying without priority"
    "$TOOL/swapon" "$DEV"
}

if [ "$prev_alg" = "$TARGET_ALG" ] && [ "$prev_size" = "$TARGET_SIZE" ]; then
    if swap_active; then
        echo "already configured and active, nothing to do"
        exit 0
    fi
    # Algorithm and size are already right, only swap is missing (e.g. a
    # previous run of this script died before swapon).  Rebuild the header.
    echo "alg/size already correct but swap is not active, re-enabling swap"
    if "$TOOL/mkswap" "$DEV" && swap_on && swap_active; then
        echo "done: alg=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$SYSFS/comp_algorithm") size=$(cat "$SYSFS/disksize") (swap re-enabled)"
        exit 0
    fi
    echo "ERROR: could not re-enable swap on the existing device"
    exit 1
fi

restore_previous() {
    echo "restoring previous configuration (alg=${prev_alg:-?} size=${prev_size:-0})"
    "$TOOL/swapoff" "$DEV" 2>/dev/null
    if ! echo 1 > "$SYSFS/reset"; then
        echo "WARN: reset failed while restoring (device still in use?)"
        return 1
    fi
    if [ -n "$prev_alg" ]; then
        echo "$prev_alg" > "$SYSFS/comp_algorithm" || echo "WARN: could not restore comp_algorithm"
    fi
    if [ -n "$prev_size" ] && [ "$prev_size" != "0" ]; then
        echo "$prev_size" > "$SYSFS/disksize" || echo "WARN: could not restore disksize"
        "$TOOL/mkswap" "$DEV" && swap_on
    fi
    return 0
}

if swap_active; then
    "$TOOL/swapoff" "$DEV" || { echo "ERROR: swapoff failed"; exit 1; }
fi

echo 1 > "$SYSFS/reset" || { echo "ERROR: zram reset failed"; restore_previous; exit 1; }

if ! echo "$TARGET_ALG" > "$SYSFS/comp_algorithm"; then
    echo "ERROR: comp_algorithm rejected '$TARGET_ALG'"
    restore_previous
    exit 1
fi

if ! echo "$TARGET_SIZE" > "$SYSFS/disksize"; then
    echo "ERROR: disksize $TARGET_SIZE rejected"
    restore_previous
    exit 1
fi

new_size=$(cat "$SYSFS/disksize")
if [ "$new_size" != "$TARGET_SIZE" ]; then
    echo "ERROR: disksize reads back '$new_size', expected $TARGET_SIZE"
    restore_previous
    exit 1
fi

if ! "$TOOL/mkswap" "$DEV"; then
    echo "ERROR: mkswap failed"
    restore_previous
    exit 1
fi

if ! swap_on || ! swap_active; then
    echo "ERROR: swapon failed; zram0 left at alg=$TARGET_ALG size=$TARGET_SIZE with no swap"
    exit 1
fi

echo "done: alg=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$SYSFS/comp_algorithm") size=$(cat "$SYSFS/disksize")"
