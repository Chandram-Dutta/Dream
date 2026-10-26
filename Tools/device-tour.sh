#!/bin/zsh
# Runs one request on the connected iPhone on Grok, as a launch-only override so the stored
# model setting is untouched. Waits until it's done, then screenshots the page while
# -DreamTour scrolls it. Build and install first (see ROADMAP.md).
# Usage: Tools/device-tour.sh <output folder> "request"
DEVICE=${DREAM_DEVICE:-00008150-000E4D423A82401C}
out=$1; request=$2
mkdir -p "$out"
log="$out/console.log"
xcrun devicectl device process launch --device $DEVICE --terminate-existing --console com.chandramdutta.dream -- -provider xai -DreamAutoIntent "$request" -DreamTour 1 > "$log" 2>&1 &
launcher=$!
for i in {1..120}; do
  sleep 1
  grep -q "\[Dream\] Done in\|\[Dream\] Failed" "$log" && break
done
sleep 2
xcrun devicectl device capture screenshot --device $DEVICE --destination "$out/0.png" -q
for step in 1 2 3 4 5; do
  sleep 5
  xcrun devicectl device capture screenshot --device $DEVICE --destination "$out/$step.png" -q
done
kill $launcher 2>/dev/null
grep "^\[Dream\]" "$log" | head -20
