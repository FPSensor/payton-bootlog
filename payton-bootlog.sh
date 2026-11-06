#!/system/bin/sh
# See payton-bootlog.rc.
P=/mnt/vendor/persist
D=$P/bootlog

mkdir -p $D
rm -rf $D/prev
[ -d $D/cur ] && mv $D/cur $D/prev
mkdir -p $D/cur
cd $D/cur || exit 1

# Keep the previous boot's pstore (its panic or console) right away: if
# this boot dies too, its own panic replaces the record in ramoops.
mkdir -p pstore
for f in /sys/fs/pstore/*; do
    [ -f "$f" ] && tail -c 524288 "$f" > "pstore/${f##*/}"
done
sync

# androidboot.payton.cpumax=<kHz> caps every cpufreq policy (bring-up test
# for DVFS voltage problems under load). Re-applied on every iteration in
# case something else raises it.
cpumax=$(getprop ro.boot.payton.cpumax)

cap_cpufreq() {
    [ -n "$cpumax" ] || return
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        max=$(cat $pol/cpuinfo_max_freq)
        cap=$cpumax
        [ "$cap" -gt "$max" ] && cap=$max
        echo $cap > $pol/scaling_max_freq
    done
}

# One line per iteration: uptime, current frequency of each policy, and
# every thermal zone as type=temp.
trend() {
    line="$(cut -d' ' -f1 /proc/uptime)"
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        line="$line ${pol##*/}=$(cat $pol/scaling_cur_freq)/$(cat $pol/scaling_max_freq)"
    done
    for tz in /sys/class/thermal/thermal_zone*; do
        line="$line $(cat $tz/type)=$(cat $tz/temp)"
    done
    echo "$line" >> trend.txt
}

# Stack traces of the processes the boot waits on, taken once the boot has
# been going for a while (debuggerd needs root, which adb cannot get yet).
dump_traces() {
    mkdir -p traces
    for name in system_server surfaceflinger \
            android.hardware.graphics.composer@2.1-service \
            vendor.qti.hardware.display.allocator-service \
            bootanimation servicemanager hwservicemanager; do
        for pid in $(pidof $name); do
            debuggerd -b $pid > traces/$name-$pid-native.txt 2>&1
        done
    done
    for pid in $(pidof system_server); do
        debuggerd -j $pid > traces/system_server-$pid-java.txt 2>&1
    done
    ps -A -T -o PID,TID,USER,S,WCHAN,PCPU,NAME > traces/ps-threads.txt 2>&1
    for pid in $(pidof system_server) $(pidof surfaceflinger) \
            $(pidof android.hardware.graphics.composer@2.1-service) \
            $(pidof bootanimation); do
        for t in /proc/$pid/task/*; do
            echo "== $t $(cat $t/comm)"
            cat $t/stack
        done
    done > traces/kernel-stacks.txt 2>&1
    sync
}
traced=0

SPAM='presentOrValidate failed|chooseCompositionStrategy failed|trackPendingFrame: Invalid present fence|Composition strategies exhausted|PrepareLayerStack: Prepare failed'

echo "cpumax=${cpumax:-none}" > trend.txt

n=0
while true; do
    # Never fill persist: stop writing below 12 MiB free.
    free=$(df -k $P | awk 'NR==2 {print $4}')
    if [ -n "$free" ] && [ "$free" -lt 12288 ]; then
        echo "persist low on space ($free KiB), stopping" > stopped.txt
        sync
        exit 0
    fi

    cap_cpufreq
    trend
    echo "iteration $n uptime $(cat /proc/uptime)" > status.txt
    # /persist is only 32 MiB and holds calibration and DRM data: keep just
    # the tail of the logs there. The full ones go to /data when it is up.
    dmesg 2>&1 | tail -c 1048576 > dmesg.txt
    # Drop the per-frame composer errors, which otherwise fill the buffer
    # within a second. Keep the head (where the display first fails) and
    # the tail.
    logcat -d -b all -v threadtime > /dev/.bootlog.all 2>&1
    grep -vE "$SPAM" /dev/.bootlog.all > /dev/.bootlog.tmp
    # Freeze the head and the first errors once the composer starts
    # failing, before the log buffers rotate them away.
    if [ ! -e head.frozen ]; then
        head -c 3145728 /dev/.bootlog.tmp > logcat-head.txt
        grep -m 300 -E "$SPAM" /dev/.bootlog.all > logcat-spam-first.txt
        [ -s logcat-spam-first.txt ] && echo "$(cat /proc/uptime)" > head.frozen
    fi
    tail -c 1572864 /dev/.bootlog.tmp > logcat.txt
    rm -f /dev/.bootlog.tmp /dev/.bootlog.all
    if [ -d /data/local/tmp ]; then
        mkdir -p /data/local/tmp/bootlog-full
        dmesg > /data/local/tmp/bootlog-full/dmesg.txt 2>&1
        logcat -d -b all -v threadtime > /data/local/tmp/bootlog-full/logcat.txt 2>&1
        chmod -R a+rX /data/local/tmp/bootlog-full
    fi
    getprop > props.txt 2>&1
    ps -A -o PID,PPID,USER,S,WCHAN,PCPU,NAME > ps.txt 2>&1
    cat /proc/pressure/* > pressure.txt 2>/dev/null
    sync

    # Bring-up: enable LineageOS' adb root setting. It lives on /data and
    # cannot be toggled without the Settings UI. Only write it once init has
    # created /data/adbroot itself: init sets an encryption policy on that
    # directory and reboots to recovery if it already exists with content.
    if [ -d /data/adbroot ] && [ ! -e /data/adbroot/enabled ]; then
        echo 1 > /data/adbroot/enabled
    fi

    # Mirror the logs where adb can pull them without root.
    if [ -d /data/local/tmp ]; then
        rm -rf /data/local/tmp/bootlog
        cp -r $D /data/local/tmp/bootlog
        chmod -R a+rX /data/local/tmp/bootlog
    fi

    up=$(cut -d. -f1 /proc/uptime)
    if [ $traced -lt 2 ] && [ $up -ge $((90 + traced * 60)) ]; then
        dump_traces
        mv traces traces-$up
        traced=$((traced + 1))
    fi

    n=$((n + 1))
    sleep 2
done
