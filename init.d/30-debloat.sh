#!/bin/sh
# Stop and runtime-mask telemetry/bloat services.
# Uses /run/systemd/transient/ so masks are volatile — re-applied each boot by HBC's run-parts.
# Modify the SERVICES list to add/remove targets; reboot to re-enable anything removed.

SERVICES="
  contentminer.service
  nudge.service
  rdxd.service
  remotelogger.service
  com.webos.service.camera.service
  voiceconductor.service
  voiceinput.service
"

if ! which systemctl >/dev/null 2>&1; then
  echo "30-debloat: systemctl not found, skipping"
  exit 0
fi

mkdir -p /run/systemd/transient

for unit in $SERVICES; do
  ln -sf /dev/null "/run/systemd/transient/${unit}"
done

systemctl daemon-reload 2>/dev/null

for unit in $SERVICES; do
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    systemctl stop "${unit}" 2>/dev/null && echo "30-debloat: stopped ${unit}" || echo "30-debloat: stop failed for ${unit}"
  else
    echo "30-debloat: ${unit} already inactive"
  fi
done

echo "30-debloat: done"
