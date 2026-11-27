#!/bin/bash
# Replays a synthetic 120 Hz trackpad gesture inside Safarium (app must run with SAFARIUM_SCROLL_DEBUG=1, which also
# logs every trackpad event's engine state to /tmp/safarium-scroll.log). See DebugTrackpadReplay.swift.
#   scripts/flicker/fling.sh "<fingerDy> <fingerFrames> <momentumDy0> <decay> [xFrac yFrac]"   (fingerDy > 0 = scroll up)
# e.g. hard fling to top: fling.sh "40 8 60 0.955"   finger pull at top: fling.sh "10 40 0"
D=$(cd "$(dirname "$0")" && pwd)
if [[ ! -x $D/.fling ]]; then
  printf '%s\n' 'import Foundation' \
    'DistributedNotificationCenter.default().postNotificationName(Notification.Name("SafariumDebugFling"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)' \
    'RunLoop.main.run(until: Date().addingTimeInterval(0.05))' > "$D/.fling.swift"
  swiftc -O "$D/.fling.swift" -o "$D/.fling" 2>/dev/null
fi
exec "$D/.fling" "${1:-40 8 60 0.955}"
