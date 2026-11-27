#!/bin/bash
# scripts/flicker/order.sh front|back — lift Safarium's window above other apps without activating it, or send it back
# (needs SAFARIUM_SCROLL_DEBUG=1). Occluded windows get throttled main-thread frames, so measure scroll while in front.
D=$(cd "$(dirname "$0")" && pwd)
if [[ ! -x $D/.order ]]; then
  printf '%s\n' 'import Foundation' \
    'DistributedNotificationCenter.default().postNotificationName(Notification.Name("SafariumDebugOrderWindow"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)' \
    'RunLoop.main.run(until: Date().addingTimeInterval(0.05))' > "$D/.order.swift"
  swiftc -O "$D/.order.swift" -o "$D/.order" 2>/dev/null
fi
exec "$D/.order" "${1:-front}"
