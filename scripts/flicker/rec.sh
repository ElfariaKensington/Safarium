#!/bin/bash
# Frame-accurate flicker check for Safarium (see memory: navigation-freeze-frame).
#   scripts/flicker/rec.sh <name> <seconds> -- <command...>
# Records the Safarium window at display rate (ScreenCaptureKit, works when covered) into /tmp/safarium-rec/<name>,
# runs <command> 0.4 s in, then prints frames that changed (diff>1) with top-bar/web luma and web std-dev
# (sd < ~6 = a flat, blank frame). Example:
#   scripts/flicker/rec.sh link 3 -- node scripts/flicker/cdp.mjs dvntm "location.href='https://en.wikipedia.org/'"
#   python3 scripts/flicker/sheet.py /tmp/safarium-rec/link 40,41,42 /tmp/sheet.png   # contact sheet of frames
D=$(cd "$(dirname "$0")" && pwd); OUT=/tmp/safarium-rec/$1; secs=$2; shift 3
[[ -x $D/.wrec ]] || swiftc -O "$D/wrec.swift" -o "$D/.wrec" 2>/dev/null
rm -rf "$OUT"; mkdir -p "$OUT"
"$D/.wrec" "${WID:-Safarium}" "$secs" "$OUT" > "$OUT/wrec.log" 2>&1 &
P=$!
for i in $(seq 50); do grep -q REC_STARTED "$OUT/wrec.log" && break; sleep 0.1; done
sleep 0.4
"$@" > "$OUT/cmd.log" 2>&1
wait $P
python3 "$D/ana.py" "$OUT"
