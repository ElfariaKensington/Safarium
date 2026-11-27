// usage: node prof.mjs <urlSubstring> <ms> -- <shell command run while profiling>
// CPU-profiles the page's main thread while the command runs; prints top self-time functions.
import { execSync } from 'node:child_process';
const [,, match, ms, , ...cmd] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = {};
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend[d.id]) { pend[d.id](d.result); delete pend[d.id]; } };
const send = (method, params = {}) => new Promise(r => { pend[++id] = r; ws.send(JSON.stringify({ id, method, params })); });
await send('Profiler.enable'); await send('Profiler.setSamplingInterval', { interval: 200 }); await send('Profiler.start');
if (cmd.length) execSync(cmd.join(' '), { stdio: 'inherit' });
await new Promise(r => setTimeout(r, +ms));
const { profile } = await send('Profiler.stop');
const byId = new Map(profile.nodes.map(n => [n.id, n]));
const self = new Map(); const dt = profile.timeDeltas; const total = (profile.endTime - profile.startTime) / 1000;
profile.samples.forEach((s, i) => { const n = byId.get(s); const k = `${n.callFrame.functionName || '(anon)'} ${n.callFrame.url.split('/').pop().slice(0, 40)}:${n.callFrame.lineNumber}`; self.set(k, (self.get(k) || 0) + (dt[i] || 0) / 1000); });
console.log('total ms', total.toFixed(0));
[...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25).forEach(([k, v]) => console.log(v.toFixed(1).padStart(8), k));
// Callers of the top native (url-less) hotspot, with time.
const parent = new Map(); profile.nodes.forEach(n => (n.children || []).forEach(c => parent.set(c, n.id)));
const hot = process.env.HOT || 'elementsFromPoint'; const chains = new Map();
profile.samples.forEach((s, i) => { let n = byId.get(s); if (n.callFrame.functionName !== hot) return; const ch = []; let p = parent.get(n.id);
  while (p && ch.length < 6) { const f = byId.get(p).callFrame; ch.push(`${f.functionName || '(anon)'}@${f.url.split('/').pop().slice(0, 30)}:${f.lineNumber}`); p = parent.get(p); }
  const k = ch.join(' < '); chains.set(k, (chains.get(k) || 0) + (dt[i] || 0) / 1000); });
[...chains.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).forEach(([k, v]) => console.log(v.toFixed(1).padStart(8), k));
process.exit(0);
