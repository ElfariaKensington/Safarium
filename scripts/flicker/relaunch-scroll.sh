#!/bin/bash
# Restarts the built Safarium in the background with CDP on 9222 and scroll diagnostics on, then opens $1 (if given).
cd "$(dirname "$0")/../.." || exit 1
pkill -f "build/Safarium.app/Contents/MacOS/Safarium$"; sleep 1.5
: > /tmp/safarium-scroll.log
open -g -n --env SAFARIUM_REMOTE_DEBUGGING_PORT=9222 --env SAFARIUM_SCROLL_DEBUG=1 build/Safarium.app
for i in $(seq 40); do curl -s --max-time 1 localhost:9222/json >/dev/null 2>&1 && break; sleep 0.25; done
sleep 1.5
[[ -n $1 ]] && node scripts/flicker/cdp.mjs "" "location.href='$1'" >/dev/null && sleep 7
exit 0
