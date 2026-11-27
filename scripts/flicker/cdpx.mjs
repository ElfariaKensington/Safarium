// node cdpx.mjs <match> <json-array-of-[method,params]>  — runs CDP commands sequentially on one session
const [,, match, cmds] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
if (!t) { console.error('no target'); process.exit(1); }
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map();
ws.onmessage = m => { const d = JSON.parse(m.data); if (pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
const call = (method, params={}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({id:i, method, params})); });
for (const [m, p, wait] of JSON.parse(cmds)) { const r = await call(m, p); console.log(m, JSON.stringify(r.result ?? r.error).slice(0, 300)); if (wait) await new Promise(r => setTimeout(r, wait)); }
ws.close(); process.exit(0);
