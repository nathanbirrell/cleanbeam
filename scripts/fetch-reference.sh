#!/bin/sh
# Clone or update the upstream projects studied in reference/.
set -e
cd "$(dirname "$0")/../reference" 2>/dev/null || { mkdir -p "$(dirname "$0")/../reference"; cd "$(dirname "$0")/../reference"; }
for repo in webosbrew/webos-homebrew-channel rorygallagher2024/glasshouse OmkarK97/webos-vibehack; do
  name=${repo#*/}
  if [ -d "$name" ]; then git -C "$name" pull --ff-only; else git clone --depth 1 "https://github.com/$repo.git"; fi
done
