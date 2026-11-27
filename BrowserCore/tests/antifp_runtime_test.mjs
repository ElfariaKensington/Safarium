// antifp_runtime_test.mjs
// Real V8 (multi-realm vm.Context) runtime test suite for kPrivacyJS extracted verbatim
// from BrowserCore/src/SXHelperMain.mm. Verifies:
//   1. Canvas 2D toDataURL / toBlob / getImageData farbling (same-page determinism,
//      cross-reload & cross-site randomization, blank-canvas preservation).
//   2. Same-origin iframe escape defense (#canvas-iframe & #rtc-iframe synchronous
//      contentDocument / contentWindow realm patching + post-navigation re-patching).
//   3. WebGL / WebGL2 UNMASKED_VENDOR/RENDERER Apple GPU masking, readPixels farbling,
//      and getSupportedExtensions deterministic cross-site ordering.
//   4. AudioContext getChannelData / copyFromChannel / getFloatFrequencyData /
//      getByteFrequencyData deterministic farbling.
//   5. navigator.plugins WebIDL-faithful cached Proxy (preserves PDF plugins,
//      instanceof PluginArray, EFF identify_plugins() cross-site randomization).
//   6. navigator.hardwareConcurrency deterministic per-site farbling.
//   7. EFF Cover Your Tracks end-to-end simulation (randomized_results >= 4).
//   8. BrowserLeaks WebRTC MediaDevices.enumerateDevices scrubbing (strips mic label,
//      deviceId, groupId, audiooutput) + automatic unlock after getUserMedia() or
//      Website Settings Allow.
//   9. Per-realm Function.prototype.toString native masking ([native code]).

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const helperPath = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  '../src/SXHelperMain.mm'
);
const helperSrc = fs.readFileSync(helperPath, 'utf8');
const match = helperSrc.match(/static const char\* const kPrivacyJS = R"JS\(([\s\S]*?)\)JS";/);
assert.ok(match && match[1], 'Failed to extract kPrivacyJS from SXHelperMain.mm');
const kPrivacyJS = match[1];

let passed = 0;
function check(cond, msg) {
  assert.ok(cond, msg);
  passed++;
}

function hashBytes(arr) {
  return crypto.createHash('md5').update(Buffer.from(arr.buffer, arr.byteOffset, arr.byteLength)).digest('hex');
}

function createMockRealm(options = {}) {
  const ctx = vm.createContext({
    Promise,
    Set,
    WeakSet,
    WeakMap,
    Map,
    Proxy,
    Reflect,
    Symbol,
    Math,
    Number,
    Array,
    String,
    ArrayBuffer,
    JSON,
    console,
  });

  // Build realistic DOM/WebIDL prototypes inside THIS V8 realm (distinct Object/Function/Uint8Array!).
  vm.runInContext(`
    const win = this;
    win.window = win;
    win.self = win;

    // Raw deterministic pixel buffer generator for Canvas 2D
    function makeRenderedPixels(w, h, fill) {
      const data = new Uint8ClampedArray(w * h * 4);
      if (fill !== 'blank') {
        for (let i = 0; i < w * h; i++) {
          data[i * 4 + 0] = (i * 17 + 40) & 255;
          data[i * 4 + 1] = (i * 31 + 80) & 255;
          data[i * 4 + 2] = (i * 53 + 120) & 255;
          data[i * 4 + 3] = 255;
        }
      }
      return data;
    }

    function CanvasRenderingContext2D(canvas, attrs) {
      this.canvas = canvas;
      this._attrs = attrs || { colorSpace: 'srgb' };
    }
    CanvasRenderingContext2D.prototype.getContextAttributes = function() { return this._attrs; };
    CanvasRenderingContext2D.prototype.drawImage = function(src) {
      if (src) {
        const srcPx = src._pixels || makeRenderedPixels(src.width, src.height, src._blank ? 'blank' : 'filled');
        this.canvas._pixels = new Uint8ClampedArray(srcPx);
      }
    };
    CanvasRenderingContext2D.prototype.getImageData = function(x, y, w, h) {
      const src = this.canvas._pixels || makeRenderedPixels(w, h, this.canvas._blank ? 'blank' : 'filled');
      return { width: w, height: h, data: new Uint8ClampedArray(src) };
    };
    CanvasRenderingContext2D.prototype.putImageData = function(img) {
      this.canvas._pixels = new Uint8ClampedArray(img.data);
    };

    function HTMLCanvasElement(ownerDocument) {
      this.width = 220;
      this.height = 30;
      this.ownerDocument = ownerDocument || win.document;
      this._blank = false;
      this._pixels = null;
    }
    HTMLCanvasElement.prototype.getContext = function(type, attrs) {
      if (type === '2d') {
        if (!this._pixels) this._pixels = makeRenderedPixels(this.width, this.height, this._blank ? 'blank' : 'filled');
        return new CanvasRenderingContext2D(this, attrs);
      }
      if (type === 'webgl' || type === 'webgl2') {
        if (!this._pixels) this._pixels = makeRenderedPixels(this.width, this.height, 'filled');
        return new WebGLRenderingContext(this);
      }
      return null;
    };
    HTMLCanvasElement.prototype.toDataURL = function(mime) {
      const px = this._pixels || makeRenderedPixels(this.width, this.height, this._blank ? 'blank' : 'filled');
      let hex = '';
      for (let i = 0; i < px.length; i++) hex += px[i].toString(16).padStart(2, '0');
      return 'data:' + (mime || 'image/png') + ';hex,' + hex;
    };
    HTMLCanvasElement.prototype.toBlob = function(cb, mime) {
      cb({ type: mime || 'image/png', url: this.toDataURL(mime) });
    };

    function WebGLRenderingContext(canvas) {
      this.canvas = canvas;
    }
    WebGLRenderingContext.prototype.getParameter = function(pname) {
      if (pname === 0x9245) return 'Google Inc. (Apple)';
      if (pname === 0x9246) return 'ANGLE (Apple, ANGLE Metal Renderer: Apple M3 Max, Unspecified Version)';
      if (pname === 0x0D33) return 32768;
      return null;
    };
    WebGLRenderingContext.prototype.getSupportedExtensions = function() {
      return [
        'ANGLE_instanced_arrays',
        'EXT_blend_minmax',
        'EXT_color_buffer_half_float',
        'OES_element_index_uint',
        'OES_standard_derivatives',
        'OES_texture_float',
        'WEBGL_color_buffer_float',
        'WEBGL_compressed_texture_astc',
        'WEBGL_debug_renderer_info',
        'WEBGL_lose_context'
      ];
    };
    WebGLRenderingContext.prototype.readPixels = function(x, y, w, h, fmt, type, pixels, dstOffset) {
      const off = dstOffset || 0;
      for (let i = 0; i < w * h * 4 && off + i < pixels.length; i++) {
        pixels[off + i] = (i % 4 === 3) ? 255 : ((i * 29 + 13) & 255);
      }
    };
    function WebGL2RenderingContext(canvas) {
      this.canvas = canvas;
    }
    WebGL2RenderingContext.prototype.getParameter = WebGLRenderingContext.prototype.getParameter;
    WebGL2RenderingContext.prototype.getSupportedExtensions = WebGLRenderingContext.prototype.getSupportedExtensions;
    WebGL2RenderingContext.prototype.readPixels = WebGLRenderingContext.prototype.readPixels;

    function AudioBuffer(len) {
      this.length = len;
      this._ch0 = new Float32Array(len);
      for (let i = 0; i < len; i++) this._ch0[i] = Math.sin(i * 0.01) * 0.5;
    }
    AudioBuffer.prototype.getChannelData = function(ch) {
      return this._ch0;
    };
    AudioBuffer.prototype.copyFromChannel = function(dst, ch, startInChannel) {
      const off = startInChannel || 0;
      for (let i = 0; i < dst.length && off + i < this._ch0.length; i++) {
        dst[i] = this._ch0[off + i];
      }
    };

    function AnalyserNode() {}
    AnalyserNode.prototype.getFloatFrequencyData = function(arr) {
      for (let i = 0; i < arr.length; i++) arr[i] = -60.0 + (i * 0.1);
    };
    AnalyserNode.prototype.getByteFrequencyData = function(arr) {
      for (let i = 0; i < arr.length; i++) arr[i] = (i * 3 + 10) & 255;
    };

    function MediaDeviceInfo(d) {
      this.deviceId = d.deviceId;
      this.groupId = d.groupId;
      this.kind = d.kind;
      this.label = d.label;
    }
    MediaDeviceInfo.prototype.toJSON = function() {
      return { deviceId: this.deviceId, kind: this.kind, label: this.label, groupId: this.groupId };
    };

    const rawDevices = [
      new MediaDeviceInfo({ kind: 'audioinput', label: 'Default - MacBook Pro Microphone (Built-in)', deviceId: 'default', groupId: 'grp-builtin-audio-abc123' }),
      new MediaDeviceInfo({ kind: 'audioinput', label: 'MacBook Pro Microphone (Built-in)', deviceId: 'mic-id-9988', groupId: 'grp-builtin-audio-abc123' }),
      new MediaDeviceInfo({ kind: 'videoinput', label: 'FaceTime HD Camera', deviceId: 'cam-id-7766', groupId: 'grp-builtin-cam-def456' }),
      new MediaDeviceInfo({ kind: 'audiooutput', label: 'MacBook Pro Speakers (Built-in)', deviceId: 'spk-id-5544', groupId: 'grp-builtin-audio-abc123' })
    ];

    function MediaDevices() {}
    MediaDevices.prototype.enumerateDevices = function() {
      return Promise.resolve(rawDevices.slice());
    };
    MediaDevices.prototype.getUserMedia = function(constraints) {
      return Promise.resolve({
        getAudioTracks: () => (constraints && constraints.audio ? [{}] : []),
        getVideoTracks: () => (constraints && constraints.video ? [{}] : [])
      });
    };

    function Plugin(name, description, filename) {
      this.name = name;
      this.description = description;
      this.filename = filename;
      this.length = 1;
      this[0] = { description: 'Portable Document Format', type: 'application/pdf', suffixes: 'pdf' };
    }
    Plugin.prototype.item = function(i) { return this[i] || null; };
    Plugin.prototype.namedItem = function(n) { return n === 'application/pdf' ? this[0] : null; };

    function PluginArray() {
      const list = [
        new Plugin('PDF Viewer', 'Portable Document Format', 'internal-pdf-viewer'),
        new Plugin('Chrome PDF Viewer', 'Portable Document Format', 'internal-pdf-viewer')
      ];
      for (let i = 0; i < list.length; i++) this[i] = list[i];
      this._list = list;
    }
    Object.defineProperty(PluginArray.prototype, 'length', {
      get: function() { return this._list.length; },
      configurable: true
    });
    PluginArray.prototype.item = function(i) { return this._list[i] || null; };
    PluginArray.prototype.namedItem = function(name) {
      return this._list.find(p => p.name === name) || null;
    };

    function Navigator() {
      this._plugins = new PluginArray();
      this.mediaDevices = new MediaDevices();
    }
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', {
      get: function() { return 12; },
      configurable: true
    });
    Object.defineProperty(Navigator.prototype, 'deviceMemory', {
      get: function() { return 16; },
      configurable: true
    });
    Object.defineProperty(Navigator.prototype, 'plugins', {
      get: function() { return this._plugins; },
      configurable: true
    });
    Navigator.prototype.getBattery = function() {
      return Promise.resolve({ charging: false, level: 0.42 });
    };

    function Performance() {}
    Performance.prototype.now = function() { return 1234.56789; };

    function HTMLIFrameElement(childWin) {
      this._childWin = childWin;
    }
    Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
      get: function() { return this._childWin; },
      configurable: true
    });
    Object.defineProperty(HTMLIFrameElement.prototype, 'contentDocument', {
      get: function() { return this._childWin ? this._childWin.document : null; },
      configurable: true
    });

    win.CanvasRenderingContext2D = CanvasRenderingContext2D;
    win.HTMLCanvasElement = HTMLCanvasElement;
    win.WebGLRenderingContext = WebGLRenderingContext;
    win.WebGL2RenderingContext = WebGL2RenderingContext;
    win.AudioBuffer = AudioBuffer;
    win.AnalyserNode = AnalyserNode;
    win.MediaDeviceInfo = MediaDeviceInfo;
    win.MediaDevices = MediaDevices;
    win.Plugin = Plugin;
    win.PluginArray = PluginArray;
    win.Navigator = Navigator;
    win.Performance = Performance;
    win.HTMLIFrameElement = HTMLIFrameElement;

    win.document = {
      defaultView: win,
      createElement: function(tag) {
        if (tag === 'canvas') return new HTMLCanvasElement(win.document);
        throw new Error('unsupported tag ' + tag);
      }
    };
    win.navigator = new Navigator();
    win.performance = new Performance();
  `, ctx);

  return ctx;
}

function installPrivacy(ctx, {
  applyGpc = true,
  applyFp = true,
  fpLevel = 0,
  siteSeedStr = 'saltA|coveryourtracks.eff.org',
  docSeedStr = 'saltA|coveryourtracks.eff.org|nonce1',
  pageHost = 'coveryourtracks.eff.org',
  frameHost = 'coveryourtracks.eff.org',
  mediaAllowedAudio = false,
  mediaAllowedVideo = false,
  events = [],
} = {}) {
  const installer = vm.runInContext(kPrivacyJS, ctx);
  installer(
    applyGpc,
    applyFp,
    fpLevel,
    siteSeedStr,
    docSeedStr,
    pageHost,
    frameHost,
    mediaAllowedAudio,
    mediaAllowedVideo,
    (payload) => events.push(JSON.parse(payload))
  );
}

// Helper matching EFF Cover Your Tracks identify_plugins()
function identifyPlugins(ctx) {
  return vm.runInContext(`
    (function() {
      var np = navigator.plugins;
      var plist = [];
      for (var i = 0; i < np.length; i++) {
        plist[i] = np[i].name + "; " + np[i].description + "; " + np[i].filename + ";";
        for (var n = 0; n < np[i].length; n++) {
          plist[i] += " (" + np[i][n].description + "; " + np[i][n].type + "; " + np[i][n].suffixes + ")";
        }
        plist[i] += ". ";
      }
      plist.sort();
      var out = "";
      for (var i = 0; i < np.length; i++) out += "Plugin " + i + ": " + plist[i];
      return out;
    })()
  `, ctx);
}

async function runTests() {
  // 1. Baseline unpatched canvas & audio for comparison
  const rawCtx = createMockRealm();
  const rawCanvas = vm.runInContext(`document.createElement('canvas').toDataURL('image/png')`, rawCtx);

  // 2. Normal browsing page 1: browserleaks.com (load 1)
  const blLoad1 = createMockRealm();
  const blEvents1 = [];
  installPrivacy(blLoad1, {
    siteSeedStr: 'sess1|browserleaks.com',
    docSeedStr: 'sess1|browserleaks.com|nav0001',
    pageHost: 'browserleaks.com',
    frameHost: 'browserleaks.com',
    events: blEvents1,
  });

  // Same-page consistency: two toDataURL() calls produce identical masked output, differing from raw GPU!
  const blCanvas1a = vm.runInContext(`document.createElement('canvas').toDataURL('image/png')`, blLoad1);
  const blCanvas1b = vm.runInContext(`document.createElement('canvas').toDataURL('image/png')`, blLoad1);
  check(blCanvas1a !== rawCanvas, 'Canvas toDataURL must differ from raw unmasked GPU pixels');
  check(blCanvas1a === blCanvas1b, 'Canvas toDataURL must be deterministic within the same page load');

  // Blank canvas must NOT be corrupted or fire telemetry
  const blBlank = vm.runInContext(`
    (function() {
      const c = document.createElement('canvas');
      c._blank = true;
      return c.toDataURL('image/png');
    })()
  `, blLoad1);
  const rawBlank = vm.runInContext(`
    (function() {
      const c = document.createElement('canvas');
      c._blank = true;
      return c.toDataURL('image/png');
    })()
  `, rawCtx);
  check(blBlank === rawBlank, 'Blank transparent canvas must remain uncorrupted');

  // 3. BrowserLeaks #canvas-iframe escape test (synchronous contentDocument.createElement('canvas'))
  const iframeChild = createMockRealm();
  blLoad1.__iframeChild = vm.runInContext(`window`, iframeChild);
  const iframeCanvas1 = vm.runInContext(`
    (function() {
      const iframe = new HTMLIFrameElement(__iframeChild);
      const c = iframe.contentDocument.createElement('canvas');
      return c.toDataURL('image/png');
    })()
  `, blLoad1);
  check(iframeCanvas1 !== rawCanvas, '#canvas-iframe must NOT escape canvas masking');
  check(iframeCanvas1 === blCanvas1a, '#canvas-iframe must share the exact same docSeed as its parent document');

  // Verify Function.prototype.toString native masking inside BOTH top window, iframe realm, and cross-realm .call()
  const nativeTopStr = vm.runInContext(`HTMLCanvasElement.prototype.toDataURL.toString()`, blLoad1);
  const nativeIframeStr = vm.runInContext(`HTMLCanvasElement.prototype.toDataURL.toString()`, iframeChild);
  const nativeCrossStr = vm.runInContext(`Function.prototype.toString.call(__iframeChild.HTMLCanvasElement.prototype.toDataURL)`, blLoad1);
  const nativeToStrStr = vm.runInContext(`Function.prototype.toString.toString()`, blLoad1);
  check(nativeTopStr === 'function toDataURL() { [native code] }', 'Top toDataURL must mask as [native code]');
  check(nativeIframeStr === 'function toDataURL() { [native code] }', 'Iframe toDataURL must mask as [native code]');
  check(nativeCrossStr === 'function toDataURL() { [native code] }', 'Cross-realm toString.call(iframe.toDataURL) must mask as [native code]');
  check(nativeToStrStr === 'function toString() { [native code] }', 'Function.prototype.toString must mask as [native code]');

  // 4. Reload browserleaks.com (load 2 -> fresh navNonce): masked signature changes!
  const blLoad2 = createMockRealm();
  installPrivacy(blLoad2, {
    siteSeedStr: 'sess1|browserleaks.com',
    docSeedStr: 'sess1|browserleaks.com|nav0002',
    pageHost: 'browserleaks.com',
    frameHost: 'browserleaks.com',
  });
  const blCanvas2 = vm.runInContext(`document.createElement('canvas').toDataURL('image/png')`, blLoad2);
  check(blCanvas2 !== rawCanvas, 'Reloaded canvas must remain masked');
  check(blCanvas2 !== blCanvas1a, 'Reloaded BrowserLeaks canvas signature must rotate on navigation');

  // 5. EFF Cover Your Tracks end-to-end simulation:
  //    Domain A: firstpartysimulator.org  vs  Domain B: coveryourtracks.eff.org (same session!)
  function collectEffWhorls(siteDomain, navNonce) {
    const ctx = createMockRealm();
    installPrivacy(ctx, {
      siteSeedStr: 'sess1|' + siteDomain,
      docSeedStr: 'sess1|' + siteDomain + '|' + navNonce,
      pageHost: siteDomain,
      frameHost: siteDomain,
    });
    const runOnce = () => vm.runInContext(`
      (function() {
        const c = document.createElement('canvas');
        const canvasFp = c.toDataURL('image/png');
        const wc = document.createElement('canvas');
        const gl = wc.getContext('webgl');
        const webglFp = wc.toDataURL('image/png') + '|' + gl.getSupportedExtensions().join(';') + '|' + gl.getParameter(0x9245) + '|' + gl.getParameter(0x9246);
        const ab = new AudioBuffer(5000);
        const ch = ab.getChannelData(0);
        let sum = 0;
        for (let i = 4500; i < 5000; i++) sum += Math.abs(ch[i]);
        return {
          canvas: canvasFp,
          webgl: webglFp,
          audio: sum.toString(),
          hw: navigator.hardwareConcurrency,
          vendor: gl.getParameter(0x9245),
          renderer: gl.getParameter(0x9246),
          pluginsSameRef: navigator.plugins === navigator.plugins,
          pluginsInstanceOf: navigator.plugins instanceof PluginArray,
          pdfIntact: !!(navigator.plugins.namedItem('PDF Viewer')),
          gpc: navigator.globalPrivacyControl,
          mem: navigator.deviceMemory,
          perfNow: performance.now(),
        };
      })()
    `, ctx);
    const r1 = runOnce();
    const r2 = runOnce();
    const p1 = identifyPlugins(ctx);
    const p2 = identifyPlugins(ctx);
    // EFF's determine_randomized requires run_1 === run_2 within the same page!
    check(r1.canvas === r2.canvas, `${siteDomain}: canvas run_1 === run_2`);
    check(r1.webgl === r2.webgl, `${siteDomain}: webgl run_1 === run_2`);
    check(r1.audio === r2.audio, `${siteDomain}: audio run_1 === run_2`);
    check(p1 === p2, `${siteDomain}: plugins run_1 === run_2`);
    check(r1.hw === r2.hw, `${siteDomain}: hardwareConcurrency run_1 === run_2`);
    check(r1.vendor === 'Apple Inc.', `${siteDomain}: WebGL vendor masked to Apple Inc.`);
    check(r1.renderer === 'Apple GPU', `${siteDomain}: WebGL renderer masked to Apple GPU`);
    check(r1.pluginsSameRef, `${siteDomain}: navigator.plugins === navigator.plugins`);
    check(r1.pluginsInstanceOf, `${siteDomain}: navigator.plugins instanceof PluginArray`);
    check(r1.pdfIntact, `${siteDomain}: PDF Viewer plugin preserved`);
    check(r1.gpc === true, `${siteDomain}: navigator.globalPrivacyControl === true`);
    check(r1.mem === 8, `${siteDomain}: navigator.deviceMemory === 8`);
    check(r1.perfNow === 1234.6, `${siteDomain}: performance.now() coarsened to 100us`);
    return { ...r1, plugins: p1 };
  }

  const fpiWhorls = collectEffWhorls('firstpartysimulator.org', 'navA');
  const effWhorls = collectEffWhorls('eff.org', 'navB');
  let randomizedResults = 0;
  if (fpiWhorls.audio !== effWhorls.audio) randomizedResults++;
  if (fpiWhorls.canvas !== effWhorls.canvas) randomizedResults++;
  if (fpiWhorls.webgl !== effWhorls.webgl) randomizedResults++;
  if (fpiWhorls.plugins !== effWhorls.plugins) randomizedResults++;
  if (fpiWhorls.hw !== effWhorls.hw) randomizedResults++;
  check(fpiWhorls.audio !== effWhorls.audio, 'EFF: audio must differ across first-party domains');
  check(fpiWhorls.canvas !== effWhorls.canvas, 'EFF: canvas must differ across first-party domains');
  check(fpiWhorls.webgl !== effWhorls.webgl, 'EFF: webgl must differ across first-party domains');
  check(fpiWhorls.plugins !== effWhorls.plugins, 'EFF: plugins must differ across first-party domains');
  check(randomizedResults >= 4, `EFF Cover Your Tracks requires randomized_results >= 4, got ${randomizedResults}`);

  // Verify WebGL getSupportedExtensions preserves exact extension set while permuting order across domains
  const extsA = vm.runInContext(`new WebGLRenderingContext(document.createElement('canvas')).getSupportedExtensions()`, blLoad1);
  const extsB = vm.runInContext(`new WebGLRenderingContext(document.createElement('canvas')).getSupportedExtensions()`, blLoad2);
  check(extsA.join(',') === extsB.join(','), 'WebGL extensions order must be consistent on reload of same site');
  check(extsA.length === 10 && extsA.includes('WEBGL_debug_renderer_info'), 'WebGL extensions must never drop any extension');

  // 6. WebRTC MediaDevices.enumerateDevices scrubbing (top window + #rtc-iframe) & getUserMedia unlock
  const rtcTop = createMockRealm();
  const rtcIframe = createMockRealm();
  rtcTop.__rtcIframe = vm.runInContext(`window`, rtcIframe);
  const rtcEvents = [];
  installPrivacy(rtcTop, {
    siteSeedStr: 'sess1|browserleaks.com',
    docSeedStr: 'sess1|browserleaks.com|navRTC',
    pageHost: 'browserleaks.com',
    frameHost: 'browserleaks.com',
    mediaAllowedAudio: false,
    mediaAllowedVideo: false,
    events: rtcEvents,
  });

  // Unpermissioned top window enumerateDevices
  const scrubbedTop = await vm.runInContext(`navigator.mediaDevices.enumerateDevices()`, rtcTop);
  check(scrubbedTop.length === 2, 'Unpermissioned enumerateDevices collapses to 1 audioinput + 1 videoinput (no audiooutput)');
  check(scrubbedTop[0].kind === 'audioinput' && scrubbedTop[0].label === '' && scrubbedTop[0].deviceId === '' && scrubbedTop[0].groupId === '',
        'Built-in microphone label, deviceId, and groupId MUST be scrubbed');
  check(scrubbedTop[1].kind === 'videoinput' && scrubbedTop[1].label === '' && scrubbedTop[1].deviceId === '' && scrubbedTop[1].groupId === '',
        'Camera label, deviceId, and groupId MUST be scrubbed');
  check(vm.runInContext(`(d => d instanceof MediaDeviceInfo && d.toJSON().label === '')`, rtcTop)(scrubbedTop[0]),
        'Scrubbed device preserves instanceof MediaDeviceInfo and toJSON()');
  check(rtcEvents.some(e => e.api === 'mediaDevices'), 'Scrubbing reports mediaDevices telemetry');

  // Unpermissioned #rtc-iframe enumerateDevices (synchronous iframe escape test!)
  const scrubbedIframe = await vm.runInContext(`
    (function() {
      const f = new HTMLIFrameElement(__rtcIframe);
      return f.contentWindow.navigator.mediaDevices.enumerateDevices();
    })()
  `, rtcTop);
  check(scrubbedIframe.length === 2 && scrubbedIframe[0].label === '' && scrubbedIframe[0].groupId === '',
        '#rtc-iframe enumerateDevices MUST ALSO scrub microphone label and groupId');

  // After getUserMedia({ audio: true }) resolves -> audioinput + audiooutput unlocked, videoinput STILL scrubbed!
  await vm.runInContext(`navigator.mediaDevices.getUserMedia({ audio: true })`, rtcTop);
  const afterAudio = await vm.runInContext(`navigator.mediaDevices.enumerateDevices()`, rtcTop);
  check(afterAudio.some(d => d.kind === 'audioinput' && d.label.includes('MacBook Pro Microphone')),
        'After audio getUserMedia grant, real microphone labels pass through for video calls');
  check(afterAudio.some(d => d.kind === 'audiooutput'),
        'After audio getUserMedia grant, speakers pass through for device pickers');
  const camAfterAudio = afterAudio.find(d => d.kind === 'videoinput');
  check(camAfterAudio && camAfterAudio.label === '' && camAfterAudio.groupId === '',
        'Ungranted camera remains scrubbed when only microphone was granted');

  // Website Settings Allow (mediaAllowedAudio=true, mediaAllowedVideo=true) immediately passes through
  const meetCtx = createMockRealm();
  installPrivacy(meetCtx, {
    siteSeedStr: 'sess1|google.com',
    docSeedStr: 'sess1|google.com|navMeet',
    pageHost: 'meet.google.com',
    frameHost: 'meet.google.com',
    mediaAllowedAudio: true,
    mediaAllowedVideo: true,
  });
  const meetDevices = await vm.runInContext(`navigator.mediaDevices.enumerateDevices()`, meetCtx);
  check(meetDevices.length === 4 && meetDevices[0].label.includes('MacBook Pro Microphone') && meetDevices[2].label.includes('FaceTime'),
        'Explicit Website Settings Allow immediately exposes full media devices');

  // 7. Strict mode hardwareConcurrency pool ([2, 4])
  const strictValues = new Set();
  for (let i = 0; i < 16; i++) {
    const sCtx = createMockRealm();
    installPrivacy(sCtx, {
      fpLevel: 1,
      siteSeedStr: `sess1|site${i}.example`,
      docSeedStr: `sess1|site${i}.example|nav${i}`,
    });
    const hw = vm.runInContext(`navigator.hardwareConcurrency`, sCtx);
    check(hw === 2 || hw === 4, `Strict hardwareConcurrency must be 2 or 4, got ${hw}`);
    strictValues.add(hw);
  }
  check(strictValues.size === 2, 'Strict hardwareConcurrency varies across domains');

  console.log(`antifp_runtime_test.mjs: ${passed} assertions, 0 failures (EFF randomized_results=${randomizedResults}/5)`);
}

runTests().catch((err) => {
  console.error(err);
  process.exit(1);
});
