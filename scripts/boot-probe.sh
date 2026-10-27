#!/bin/sh
# Read-only boot profiling. Run on the projector:
#   ssh cleanbeam 'sh -s' < scripts/boot-probe.sh > boot-probe.txt
# Nothing here changes state.

export LUNA_SOCKET=/tmp/var/run/luna-service2/com.palm.hub

# luna-send from SSH can hang after answering; cap each call.
luna() {
  luna-send -w 3000 -n 1 "$1" "$2" &
  pid=$!; sleep 3; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo
}

section() { echo; echo "===== $1 ====="; }

section uptime;          uptime; cat /proc/uptime
section cmdline;         cat /proc/cmdline
section sys-power;       for f in /sys/power/*; do [ -f "$f" ] && echo "$f: $(cat "$f" 2>/dev/null | head -c 300)"; done
section snapshot-bins;   ls -l /usr/sbin/*snapshot* /usr/bin/*snapshot* /sbin/*snapshot* 2>/dev/null
section snapshot-units;  systemctl list-unit-files 2>/dev/null | grep -iE 'snapshot|criu|instant|quick'
section snapshot-on;     systemctl cat snapshot-boot-on.service 2>&1
section snapshot-status; systemctl status snapshot-boot-on.service --no-pager 2>&1 | head -30

section analyze;         systemd-analyze 2>&1
section blame;           systemd-analyze blame 2>&1 | head -40
section critical-chain;  systemd-analyze critical-chain 2>&1 | head -60

section dmesg-snapshot;  dmesg 2>/dev/null | grep -iE 'snapshot|resume|hibern|swsusp|restore|making' | head -60
section partitions;      cat /proc/partitions; ls -l /dev/disk/by-partlabel 2>/dev/null | head -80
section checkpoints;     ls -la /tmp/checkpoint /mnt/lg/cmn_data/checkpoint 2>&1 | head -30
section bootd-log;       head -80 /var/log/bootd.log 2>&1
section tvpower-log;     ls /var/log/ 2>/dev/null; grep -ihE 'reason|snapshot|instant|suspend|quick' /var/log/tvpower* 2>/dev/null | head -40

section quickStartMode;  luna luna://com.webos.service.settings/getSystemSettings '{"category":"option","keys":["quickStartMode","standByLight"]}'
section option-all;      luna luna://com.webos.service.settings/getSystemSettings '{"category":"option"}'
section power-state;     luna luna://com.webos.service.tvpower/power/getPowerState '{}'
section power-reason;    luna luna://com.webos.service.tvpower/power/getPowerOnReason '{}'
section power-clients;   luna luna://com.webos.service.tvpower/power/getClientList '{}'
