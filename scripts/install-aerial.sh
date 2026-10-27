#!/bin/sh
# Install or update the Apple-only aerial screen saver, keeping its settings. Run from the Mac:
#   scripts/install-aerial.sh path/to/org.rchalaaa.webos.custom-screensaver_<ver>_all.ipk [ssh-host]
# Build the IPK from https://github.com/nathanbirrell/custom-screensaver
# (npm run build -- --production && ares-package dist/).
# A reinstall overwrites assets/settings.json and replaces the QML file that the screen saver
# bind-mounts, so this saves the settings, unmounts, installs, restores and mounts again.
set -e

IPK=${1:?usage: $0 <ipk> [ssh-host]}
HOST=${2:-cleanbeam}

scp -q "$IPK" "$HOST":/tmp/aerial.ipk
ssh "$HOST" 'sh -s' <<'EOF'
export LUNA_SOCKET=/tmp/var/run/luna-service2/com.palm.hub
APP=/media/developer/apps/usr/palm/applications/org.rchalaaa.webos.custom-screensaver

[ -f "$APP/assets/settings.json" ] && cp "$APP/assets/settings.json" /tmp/aerial-settings.json
[ -f "$APP/assets/unapply.sh" ] && sh "$APP/assets/unapply.sh"

# Subscribed install; luna-send never exits on its own, so stop it once the state is final.
luna-send -w 60000 -i luna://com.webos.appInstallService/dev/install \
  '{"id":"com.ares.defaultName","ipkUrl":"/tmp/aerial.ipk","subscribe":true}' > /tmp/aerial-install.log 2>&1 &
pid=$!
for i in $(seq 1 60); do
  sleep 2
  grep -q -e '"state":"installed"' -e 'errorText' -e 'FAILED' /tmp/aerial-install.log && break
done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
if ! grep -q '"state":"installed"' /tmp/aerial-install.log; then
  echo "install failed:"; tail -c 600 /tmp/aerial-install.log; exit 1
fi

[ -f /tmp/aerial-settings.json ] && cp /tmp/aerial-settings.json "$APP/assets/settings.json"
sh "$APP/assets/apply.sh"
# The app's Enable toggle normally writes this boot hook; write it here so a fresh install works too.
printf '%s\n' '#!/bin/sh' "sh $APP/assets/apply.sh" > /var/lib/webosbrew/init.d/50-custom-screensaver-aerial
chmod +x /var/lib/webosbrew/init.d/50-custom-screensaver-aerial

grep '"version"' "$APP/appinfo.json"
echo "videos: $(grep -c '"id"' "$APP/assets/videos.json")"
rm -f /tmp/aerial.ipk /tmp/aerial-install.log /tmp/aerial-settings.json
EOF
