// node click.mjs <urlSubstring> <x> <y> — real mouse click (CSS px, viewport) through CDP Input on a page target;
// reaches cross-origin iframes (extension overlays) the same way a user click does.
const [,, match, x, y] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = {};
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend[d.id]) { pend[d.id](d); delete pend[d.id]; } };
const send = (method, params) => new Promise(r => { pend[++id] = r; ws.send(JSON.stringify({ id, method, params })); });
const base = { x: +x, y: +y, button: 'left', clickCount: 1 };
await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: +x, y: +y });
await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
process.exit(0);
