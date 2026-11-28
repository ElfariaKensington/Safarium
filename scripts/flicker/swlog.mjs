// node swlog.mjs <targetUrlSubstring> <ms> — print console errors/exceptions from a target (e.g. extension service worker).
const [,, match, ms] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.url.includes(match) && t.webSocketDebuggerUrl);
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
ws.onmessage = m => { const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') console.log('EXC', d.params.exceptionDetails.exception?.description?.slice(0, 400) || d.params.exceptionDetails.text);
  if (d.method === 'Runtime.consoleAPICalled' && /error|warn/.test(d.params.type)) console.log('CON', d.params.type, d.params.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 400)); };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.enable' }));
await new Promise(r => setTimeout(r, +ms));
process.exit(0);
