// node frame.mjs <urlSubstring> <expr> — evaluate in any CDP target (iframes, extension service workers, popouts)
const [,, match, expr] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.url.includes(match) && t.webSocketDebuggerUrl);
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id === 1) { console.log(JSON.stringify(d.result?.result?.value ?? d.result)); process.exit(0); } };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true, awaitPromise: true, userGesture: true } }));
