// node dom.mjs <urlSubstring> — iframes in the page, including closed shadow roots (DOM.getDocument pierce):
// inline style, box model and the host chain. For inspecting extension-injected overlays.
const [,, match] = process.argv;
const list = await (await fetch('http://localhost:9222/json')).json();
const t = list.find(t => t.type === 'page' && t.url.includes(match));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = {};
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend[d.id]) { pend[d.id](d.result || d.error); delete pend[d.id]; } };
const send = (method, params = {}) => new Promise(r => { pend[++id] = r; ws.send(JSON.stringify({ id, method, params })); });
const { root } = await send('DOM.getDocument', { depth: -1, pierce: true });
const out = [];
const walk = (n, chain) => {
  const attrs = {}; for (let i = 0; i < (n.attributes || []).length; i += 2) attrs[n.attributes[i]] = n.attributes[i + 1];
  if (n.nodeName === 'IFRAME' && /chrome-extension/.test(attrs.src || '')) out.push({ n, attrs, chain });
  const kids = [...(n.children || []), ...(n.shadowRoots || []), ...(n.contentDocument ? [] : [])];
  kids.forEach(k => walk(k, chain.concat(n.nodeName + (n.shadowRootType ? '(' + n.shadowRootType + ')' : ''))));
};
walk(root, []);
for (const { n, attrs, chain } of out) {
  const box = await send('DOM.getBoxModel', { nodeId: n.nodeId });
  const st = (attrs.style || '').split(';').map(s => s.trim()).filter(s => /^(position|top|left|width|height|display|opacity|visibility|transform|inset|background|pointer-events|clip|z-index)/.test(s));
  console.log((attrs.src || '').replace(/.*overlay\//, ''), 'box=', box.model ? box.model.border.slice(0, 2).concat(box.model.width, box.model.height).map(Math.round).join(',') : box.message);
  console.log('   style:', st.join('; '));
  console.log('   chain:', chain.slice(-4).join(' > '));
}
process.exit(0);
