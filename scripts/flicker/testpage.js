// Builds a long, light test page of unique noise blocks (for scroll smoothness measurement); run via cdp.mjs.
(()=>{document.body.innerHTML='';document.body.style.margin='0';document.title='sx-scroll-test';
let s=12345;const r=()=>(s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff;
for(let i=0;i<400;i++){const d=document.createElement('div');d.style.cssText='height:48px;display:flex';
for(let j=0;j<24;j++){const c=document.createElement('span');c.style.cssText='flex:1;background:hsl('+Math.floor(r()*360)+','+(40+Math.floor(r()*50))+'%,'+(25+Math.floor(r()*50))+'%)';d.appendChild(c)}
document.body.appendChild(d)}return document.body.scrollHeight})()
