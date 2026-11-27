// usage: node key.mjs <urlSubstring> space|shift-space [count=1] [gapMs=0] [repeatTail=0]
// Sends real Space keydown/keyup through CDP (reaches the page's keydown handler -> Safarium Space scroll).
// repeatTail > 0 holds the key: that many extra keydowns with autoRepeat every 33 ms before keyup.
const [,, match, which = 'space', count = '1', gap = '0', tail = '0'] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = {};
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend[d.id]) { pend[d.id](d); delete pend[d.id]; } };
const send = (method, params) => new Promise(r => { pend[++id] = r; ws.send(JSON.stringify({ id, method, params })); });
const mods = which === 'shift-space' ? 8 : 0;
const key = { key: ' ', code: 'Space', windowsVirtualKeyCode: 32, nativeVirtualKeyCode: 49, text: ' ', modifiers: mods };
const sleep = ms => new Promise(r => setTimeout(r, ms));
for (let i = 0; i < +count; i++) {
  await send('Input.dispatchKeyEvent', { type: 'keyDown', ...key });
  for (let j = 0; j < +tail; j++) { await sleep(33); await send('Input.dispatchKeyEvent', { type: 'keyDown', autoRepeat: true, ...key }); }
  await send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
  if (+gap) await sleep(+gap);
}
process.exit(0);
