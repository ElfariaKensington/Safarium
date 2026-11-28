// node iso.mjs <urlSubstring> <worldNameSubstring> <expr> — evaluate in an extension's isolated world of a page.
const [,, match, world, expr] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
const ctxs = []; let res = null;
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.method === 'Runtime.executionContextCreated') ctxs.push(d.params.context); if (d.id === 2) res = d; };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.enable' }));
await new Promise(r => setTimeout(r, 600));
const c = ctxs.find(c => (c.name || '').includes(world));
if (!c) { console.log('no context'); process.exit(1); }
ws.send(JSON.stringify({ id: 2, method: 'Runtime.evaluate', params: { expression: expr, contextId: c.id, returnByValue: true, awaitPromise: true } }));
for (let i = 0; i < 60 && !res; i++) await new Promise(r => setTimeout(r, 100));
console.log(JSON.stringify(res && (res.result.result.value ?? res.result)));
process.exit(0);
