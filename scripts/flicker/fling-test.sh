#!/bin/bash
# End-to-end fling-to-top check (see memory: reddit-scroll-overshoot). Usage: scripts/flicker/fling-test.sh <urlSubstring> [startY] [spec]
# Lifts the window (no activation), scrolls to startY, replays a trackpad fling, then prints the page's frame gaps,
# where the shell launched the top overshoot (renderer scrollY / estimate / impact velocity) and the peak overshoot.
D=$(cd "$(dirname "$0")" && pwd); M=$1; Y=${2:-1500}; SPEC=${3:-"40 8 60 0.955"}
"$D/order.sh" front; sleep 0.4
node "$D/cdp.mjs" "$M" "(()=>{scrollTo(0,$Y);window.__p=[];const t0=performance.now();(function f(){__p.push(performance.now()-t0);if(performance.now()-t0<2600)requestAnimationFrame(f)})();return scrollY})()" >/dev/null
sleep 0.5; : > /tmp/safarium-scroll.log
"$D/fling.sh" "$SPEC"; sleep 2.4
node "$D/cdp.mjs" "$M" "(()=>{const g=[];for(let i=1;i<__p.length;i++)g.push(Math.round(__p[i]-__p[i-1]));g.sort((a,b)=>b-a);return 'frames '+__p.length+' worstGaps '+g.slice(0,6).join(',')+' endY '+Math.round(scrollY)})()"
"$D/order.sh" back
L=$(grep -v "monitor\|replay" /tmp/safarium-scroll.log)
echo "events $(echo "$L" | wc -l | tr -d ' ')  telemetry updates $(echo "$L" | awk '{print $6}' | uniq | wc -l | tr -d ' ')"
echo "launch: $(echo "$L" | grep -m1 criticallyDamped | awk '{print $4,$5,$6,$7}')"
echo "peak ov: $(echo "$L" | grep -o 'ov=[0-9.-]*' | cut -d= -f2 | sort -n | tail -1)"
