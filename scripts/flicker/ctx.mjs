// node ctx.mjs <urlSubstring> — list the page's JS execution contexts (main world + extension isolated worlds).
const [,, match] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
const ctxs = [];
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.method === 'Runtime.executionContextCreated') ctxs.push(d.params.context); };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.enable' }));
await new Promise(r => setTimeout(r, 800));
for (const c of ctxs) console.log(c.id, c.name || '(main)', c.origin, JSON.stringify(c.auxData));
process.exit(0);
