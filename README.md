# payton-bootlog

A boot logger for bringing up Android on a device that hangs or resets
before adb is usable. It was written for the Moto X4 (payton) on kernel
4.19 and lived in `device/motorola/payton/bootlog` until the port booted
reliably.

Every 2 seconds, from `post-fs` on, it writes a snapshot of the boot to
`/mnt/vendor/persist/bootlog/cur`, which survives a cold reset and can be
read from recovery. The previous boot's snapshot moves to `prev`.

## What it records

| File | Contents |
|---|---|
| `pstore/` | The previous boot's `/sys/fs/pstore` records (its panic or console), copied before this boot can overwrite them |
| `dmesg.txt` | Tail (1 MiB) of the kernel log |
| `logcat.txt` | Tail (1.5 MiB) of `logcat -b all`, without the composer spam lines (`SPAM` in the script) |
| `logcat-head.txt` | First 3 MiB of logcat, frozen the first time a `SPAM` line shows up, so the start of the boot survives buffer rotation |
| `logcat-spam-first.txt` | First 300 `SPAM` lines |
| `props.txt`, `ps.txt`, `pressure.txt` | `getprop`, processes with wait channels, PSI |
| `trend.txt` | One line per iteration: uptime, frequency of each cpufreq policy, every thermal zone |
| `traces-<uptime>/` | Native and Java stacks of system_server, surfaceflinger, the composer, the allocator, bootanimation and the service managers, plus kernel stacks of their threads. Taken at 90 s and 150 s of uptime |
| `status.txt` | Iteration number and uptime of the last write |

Once `/data` is mounted it also:

- mirrors the snapshot to `/data/local/tmp/bootlog`, readable with plain
  `adb pull`, and writes the full logs to `/data/local/tmp/bootlog-full`;
- enables LineageOS' adb root setting (`/data/adbroot/enabled`), but only
  after init itself has created `/data/adbroot`. Creating it earlier
  makes init find an unencrypted directory where it expects to set an
  encryption policy and reboot to recovery.

`androidboot.payton.cpumax=<kHz>` on the kernel command line caps every
cpufreq policy, which helps tell DVFS voltage problems from other hangs.

## Limits

`/persist` is 32 MiB and holds calibration and DRM data. The logger:

- keeps only tails of the logs there;
- stops writing (and leaves `stopped.txt`) when less than 12 MiB is free;
- keeps a single previous boot.

Do not raise these limits. A full `/persist` breaks sensors, Wi-Fi MAC
and DRM.

## Adding it to a device tree

1. Copy `payton-bootlog.sh` and `payton-bootlog.rc` into the device tree,
   for example under `bootlog/`.
2. Install them on non-user builds only. The service runs as `su`,
   which exists only in userdebug and eng:

   ```make
   ifneq ($(TARGET_BUILD_VARIANT),user)
   PRODUCT_COPY_FILES += \
       $(LOCAL_PATH)/bootlog/payton-bootlog.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/payton-bootlog.rc \
       $(LOCAL_PATH)/bootlog/payton-bootlog.sh:$(TARGET_COPY_OUT_SYSTEM)/etc/payton-bootlog.sh
   endif
   ```
3. Make sure `/mnt/vendor/persist` is mounted by `post-fs`. On msm8998
   devices the vendor fstab mounts it in first stage.
4. Optional, but useful together with it:
   - larger log buffers, `ro.logd.size=16M`;
   - a kernel with ramoops console, pmsg and dmesg records, so `pstore/`
     has something in it after a panic;
   - insecure adb at boot (`WITH_ADB_INSECURE := true`,
     `persist.sys.usb.config=adb`) to read `/data/local/tmp/bootlog`
     before the UI is up.

SELinux has to be permissive: the script reads and writes across many
domains and labels.

## Reading the logs

From recovery (TWRP), with `/persist` mounted:

```sh
adb pull /persist/bootlog
```

From Android, without root:

```sh
adb pull /data/local/tmp/bootlog
adb pull /data/local/tmp/bootlog-full
```

## Removing it

Delete the two files and the `PRODUCT_COPY_FILES` block. The snapshot
directory on `/persist` can be removed with
`rm -rf /mnt/vendor/persist/bootlog` from a root shell.
