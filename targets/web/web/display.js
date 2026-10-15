// PowOS Web's screen: QEMU's graphical console (-display web, qemu/ui/web.c) drawn on a canvas, and the canvas's
// keyboard / pointer / touch input sent back.
//
// Frames: QEMU calls Module.powosFrame(heap, ptr, w, h, stride, x, y, rw, rh) on the main thread with the surface
// (BGRX, in the shared Wasm heap) and the rectangle that changed since the last call. Dirty rectangles are merged and
// uploaded once per animation frame: WebGPU (writeTexture straight from the heap, bgra8unorm, no conversion), or a
// 2D canvas fallback (copy + BGRX->RGBA).
// Input: QEMU announces its ring (Module.powosInputRing(heap32, index, slots)); events are 4 int32
// [type, a, b, 0] - 1 key (Linux evdev code, down), 2 absolute pointer (x, y in 0..32767), 3 button (QEMU
// InputButton, down) - published with Atomics on the head index; QEMU drains the ring every 30 ms.

const EV_KEY = 1, EV_ABS = 2, EV_BTN = 3;
const BTN = { left: 0, middle: 1, right: 2, wheelUp: 3, wheelDown: 4 };

// KeyboardEvent.code -> Linux evdev keycode (linux/input-event-codes.h)
const EVDEV = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6, Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10,
  Digit0: 11, Minus: 12, Equal: 13, Backspace: 14, Tab: 15, KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20,
  KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24, KeyP: 25, BracketLeft: 26, BracketRight: 27, Enter: 28,
  ControlLeft: 29, KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43, KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47,
  KeyB: 48, KeyN: 49, KeyM: 50, Comma: 51, Period: 52, Slash: 53, ShiftRight: 54, NumpadMultiply: 55,
  AltLeft: 56, Space: 57, CapsLock: 58, F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67,
  F10: 68, NumLock: 69, ScrollLock: 70, Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74, Numpad4: 75,
  Numpad5: 76, Numpad6: 77, NumpadAdd: 78, Numpad1: 79, Numpad2: 80, Numpad3: 81, Numpad0: 82, NumpadDecimal: 83,
  IntlBackslash: 86, F11: 87, F12: 88, NumpadEnter: 96, ControlRight: 97, NumpadDivide: 98, PrintScreen: 99,
  AltRight: 100, Home: 102, ArrowUp: 103, PageUp: 104, ArrowLeft: 105, ArrowRight: 106, End: 107,
  ArrowDown: 108, PageDown: 109, Insert: 110, Delete: 111, Pause: 119, MetaLeft: 125, MetaRight: 126,
  ContextMenu: 127,
};

export function attachDisplay(Module, canvas, { onFirstFrame } = {}) {
  let surface = null;            // { heap, ptr, w, h, stride }
  let dirty = null;              // { x0, y0, x1, y1 }
  let scheduled = false;
  let draw = null;               // (surface, dirty) => void, set once a renderer is ready
  let first = true;

  // Counters for tests and the console: frames QEMU sent, input events the page pushed, and the input ring's
  // head (page) / tail (QEMU) - tail lagging behind head means QEMU is not draining input.
  const stats = Module.powosStats = { frames: 0, events: 0, ring: () => ring ? [Atomics.load(ring.h32, ring.base), Atomics.load(ring.h32, ring.base + 1)] : null };
  Module.powosFrame = (heap, ptr, w, h, stride, x, y, rw, rh) => {
    stats.frames++;
    if (!surface || surface.ptr !== ptr || surface.w !== w || surface.h !== h) {
      surface = { heap, ptr, w, h, stride };
      canvas.width = w;
      canvas.height = h;
      dirty = { x0: 0, y0: 0, x1: w, y1: h };
    } else if (!dirty) {
      dirty = { x0: x, y0: y, x1: x + rw, y1: y + rh };
    } else {
      dirty = { x0: Math.min(dirty.x0, x), y0: Math.min(dirty.y0, y),
                x1: Math.max(dirty.x1, x + rw), y1: Math.max(dirty.y1, y + rh) };
    }
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        if (draw && surface && dirty) {
          draw(surface, dirty);
          dirty = null;
          if (first) { first = false; onFirstFrame?.(); }
        }
      });
    }
  };

  // Renderer: WebGPU when available, else 2D.
  (async () => {
    try {
      if (!navigator.gpu) throw new Error('no WebGPU');
      const adapter = await navigator.gpu.requestAdapter();
      const device = await adapter.requestDevice();
      const ctx = canvas.getContext('webgpu');
      const format = navigator.gpu.getPreferredCanvasFormat();
      ctx.configure({ device, format, alphaMode: 'opaque' });
      const module = device.createShaderModule({ code: `
        @group(0) @binding(0) var tex: texture_2d<f32>;
        @group(0) @binding(1) var smp: sampler;
        struct V { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
        @vertex fn vs(@builtin(vertex_index) i: u32) -> V {
          var p = array(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
          var v: V; v.pos = vec4f(p[i], 0, 1); v.uv = vec2f((p[i].x + 1) / 2, (1 - p[i].y) / 2); return v;
        }
        @fragment fn fs(v: V) -> @location(0) vec4f { return vec4f(textureSample(tex, smp, v.uv).rgb, 1); }` });
      const pipeline = device.createRenderPipeline({ layout: 'auto',
        vertex: { module, entryPoint: 'vs' }, fragment: { module, entryPoint: 'fs', targets: [{ format }] } });
      const sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });
      let tex = null, bind = null;
      draw = (s, d) => {
        if (!tex || tex.width !== s.w || tex.height !== s.h) {
          tex?.destroy();
          tex = device.createTexture({ size: [s.w, s.h], format: 'bgra8unorm',
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
          bind = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0),
            entries: [{ binding: 0, resource: tex.createView() }, { binding: 1, resource: sampler }] });
          d = { x0: 0, y0: 0, x1: s.w, y1: s.h };
        }
        const w = d.x1 - d.x0, h = d.y1 - d.y0;
        device.queue.writeTexture({ texture: tex, origin: [d.x0, d.y0] }, s.heap,
          { offset: s.ptr + d.y0 * s.stride + d.x0 * 4, bytesPerRow: s.stride, rowsPerImage: h }, [w, h]);
        const enc = device.createCommandEncoder();
        const pass = enc.beginRenderPass({ colorAttachments: [{ view: ctx.getCurrentTexture().createView(),
          loadOp: 'clear', storeOp: 'store', clearValue: [0, 0, 0, 1] }] });
        pass.setPipeline(pipeline); pass.setBindGroup(0, bind); pass.draw(3); pass.end();
        device.queue.submit([enc.finish()]);
      };
      console.log('display: WebGPU');
    } catch (e) {
      const ctx = canvas.getContext('2d');
      draw = (s, d) => {
        const w = d.x1 - d.x0, h = d.y1 - d.y0;
        const img = ctx.createImageData(w, h);
        for (let y = 0; y < h; y++) {
          const row = s.ptr + (d.y0 + y) * s.stride + d.x0 * 4;
          for (let x = 0; x < w; x++) {
            const i = row + x * 4, o = (y * w + x) * 4;
            img.data[o] = s.heap[i + 2]; img.data[o + 1] = s.heap[i + 1]; img.data[o + 2] = s.heap[i]; img.data[o + 3] = 255;
          }
        }
        ctx.putImageData(img, d.x0, d.y0);
      };
      console.log(`display: 2D canvas (${e.message})`);
    }
  })();

  // Input ring.
  let ring = null; // { h32, base, slots }
  const pending = [];
  const push = (type, a, b) => {
    stats.events++;
    if (!ring) { if (pending.length < 256) pending.push([type, a, b]); return; }
    const { h32, base, slots } = ring;
    const head = Atomics.load(h32, base);
    const slot = base + 2 + (head % slots) * 4;
    h32[slot] = type; h32[slot + 1] = a; h32[slot + 2] = b; h32[slot + 3] = 0;
    Atomics.store(h32, base, (head + 1) % (slots * 1024));
  };
  Module.powosInputRing = (h32, base, slots) => {
    ring = { h32, base, slots };
    for (const e of pending.splice(0)) push(...e);
  };

  canvas.tabIndex = 0;
  const key = (down) => (e) => {
    const code = EVDEV[e.code];
    if (code === undefined) return;
    e.preventDefault();
    push(EV_KEY, code, down ? 1 : 0);
  };
  canvas.addEventListener('keydown', key(true));
  canvas.addEventListener('keyup', key(false));
  const abs = (e) => {
    const r = canvas.getBoundingClientRect();
    const x = Math.max(0, Math.min(32767, Math.round((e.clientX - r.left) / r.width * 32767)));
    const y = Math.max(0, Math.min(32767, Math.round((e.clientY - r.top) / r.height * 32767)));
    push(EV_ABS, x, y);
  };
  const button = (b) => b === 1 ? BTN.middle : b === 2 ? BTN.right : BTN.left;
  canvas.addEventListener('pointermove', abs);
  canvas.addEventListener('pointerdown', (e) => { canvas.focus(); abs(e); push(EV_BTN, button(e.button), 1);
                                                  canvas.setPointerCapture(e.pointerId); e.preventDefault(); });
  canvas.addEventListener('pointerup', (e) => { abs(e); push(EV_BTN, button(e.button), 0); e.preventDefault(); });
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const b = e.deltaY < 0 ? BTN.wheelUp : BTN.wheelDown;
    push(EV_BTN, b, 1); push(EV_BTN, b, 0);
  }, { passive: false });
}
