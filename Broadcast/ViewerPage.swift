import Foundation

/// The browser viewer, served from `GET /`.
///
/// Embedded as a string rather than a bundle resource because the broadcast extension
/// serves it directly and this keeps the extension to a single file read at build time.
/// Self-contained by necessity: the viewing device is on a LAN or a phone hotspot with no
/// route to the internet, so there is nothing to load a framework or font from.
enum ViewerPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Screen Mirror</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; height: 100%; background: #000; color: #e8e8ea; overflow: hidden;
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  #stage { position: fixed; inset: 0; display: grid; place-items: center; }
  /* Deliberately no max-width/max-height: fitCanvas() sets exact pixel dimensions, and
     a clamp on one axis but not the other distorts the picture whenever it is rotated,
     because the layout box stays unrotated while the transform does not. */
  canvas { display: block; image-rendering: auto; transform-origin: center center; }
  #chrome {
    position: fixed; inset: auto 0 0 0; padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
    display: flex; gap: 14px; align-items: center; flex-wrap: wrap;
    background: linear-gradient(to top, rgba(0,0,0,.85), rgba(0,0,0,0));
    transition: opacity .25s ease; opacity: 1;
  }
  #chrome.hidden { opacity: 0; pointer-events: none; }
  .pill {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 5px 10px; border-radius: 999px;
    background: rgba(255,255,255,.09); border: 1px solid rgba(255,255,255,.12);
    font-variant-numeric: tabular-nums; white-space: nowrap;
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: #f0b429; }
  .dot.live { background: #34c759; }
  .dot.dead { background: #ff453a; }
  button, select {
    font: inherit; color: inherit; padding: 5px 12px; border-radius: 999px; cursor: pointer;
    background: rgba(255,255,255,.09); border: 1px solid rgba(255,255,255,.12);
  }
  button:hover, select:hover { background: rgba(255,255,255,.16); }
  label { display: inline-flex; align-items: center; gap: 6px; opacity: .75; }
  #message {
    position: fixed; inset: 0; display: grid; place-items: center; padding: 32px;
    text-align: center; line-height: 1.6; background: #000;
  }
  #message.hidden { display: none; }
  #message .inner { max-width: 34em; }
  #message h1 { font-size: 17px; font-weight: 600; margin: 0 0 8px; }
  #message p { margin: 0; opacity: .65; }
  code { background: rgba(255,255,255,.1); padding: 1px 5px; border-radius: 4px; }
</style>
</head>
<body>
<div id="stage"><canvas id="canvas"></canvas></div>

<div id="message">
  <div class="inner">
    <h1 id="msg-title">Connecting…</h1>
    <p id="msg-body">Waiting for the broadcast to send its first frame.</p>
  </div>
</div>

<div id="chrome">
  <span class="pill"><span class="dot" id="status-dot"></span><span id="status-text">Connecting</span></span>
  <span class="pill" id="stats">—</span>
  <label>Quality
    <select id="quality">
      <option value="854">Low · 480p</option>
      <option value="1280" selected>Medium · 720p</option>
      <option value="1920">High · 1080p</option>
    </select>
  </label>
  <label>Rate
    <select id="fps">
      <option value="15">15 fps</option>
      <option value="30" selected>30 fps</option>
      <option value="60">60 fps</option>
    </select>
  </label>
  <button id="fullscreen">Fullscreen</button>
</div>

<script>
(() => {
  "use strict";

  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
  const statusDot = document.getElementById("status-dot");
  const statusText = document.getElementById("status-text");
  const statsEl = document.getElementById("stats");
  const chrome = document.getElementById("chrome");
  const message = document.getElementById("message");
  const msgTitle = document.getElementById("msg-title");
  const msgBody = document.getElementById("msg-body");

  const HEADER_BYTES = 8;
  const MAGIC = 0x54;
  const FLAG_KEYFRAME = 0x01;

  if (typeof VideoDecoder === "undefined") {
    showMessage(
      "This browser can't decode the stream",
      "The viewer needs the WebCodecs API — Safari 16.4 or newer, or a recent " +
      "Chrome, Edge or Firefox. On an iPhone or iPad, the Screen Mirror app is a better fit anyway."
    );
    return;
  }

  let socket = null;
  let decoder = null;
  // A stream joined mid-broadcast starts on a delta frame with no parameter sets, which
  // would fault the decoder. Ignore everything until the first keyframe arrives.
  let sawKeyframe = false;
  let reconnectDelay = 500;
  // Degrees the picture must be rotated to appear upright, from the frame header.
  let rotation = 0;
  let framesSinceTick = 0;
  let bytesSinceTick = 0;

  function showMessage(title, body) {
    msgTitle.textContent = title;
    msgBody.innerHTML = body;
    message.classList.remove("hidden");
  }
  function hideMessage() { message.classList.add("hidden"); }

  function setStatus(state, text) {
    statusDot.className = "dot" + (state ? " " + state : "");
    statusText.textContent = text;
  }

  function createDecoder() {
    if (decoder) { try { decoder.close(); } catch (_) {} }
    sawKeyframe = false;
    decoder = new VideoDecoder({
      output: (frame) => {
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
          fitCanvas();
        }
        ctx.drawImage(frame, 0, 0);
        frame.close();
        framesSinceTick++;
        hideMessage();
      },
      error: (err) => {
        console.warn("decoder error", err);
        // Most decoder faults are recoverable by resyncing on the next keyframe.
        createDecoder();
      },
    });
    // Omitting `description` selects Annex-B mode, so the decoder reads SPS/PPS inline
    // from the bitstream — which is exactly how the sender packages keyframes.
    decoder.configure({
      codec: "avc1.4D402A",
      optimizeForLatency: true,
      hardwareAcceleration: "prefer-hardware",
    });
  }

  function fitCanvas() {
    const cw = canvas.width, ch = canvas.height;
    if (!cw || !ch) return;
    // A quarter turn swaps which source edge has to fit which viewport edge, so the
    // bounding box is measured rotated while the canvas itself keeps its own dimensions.
    const swapped = rotation % 180 !== 0;
    const boxW = swapped ? ch : cw;
    const boxH = swapped ? cw : ch;
    const scale = Math.min(window.innerWidth / boxW, window.innerHeight / boxH);
    canvas.style.width = Math.floor(cw * scale) + "px";
    canvas.style.height = Math.floor(ch * scale) + "px";
    canvas.style.transform = rotation ? "rotate(" + rotation + "deg)" : "none";
  }
  // Both matter: `resize` catches a desktop window change or an iPad being turned,
  // `orientationchange` fires on phones where the viewport size lags the rotation.
  window.addEventListener("resize", fitCanvas);
  window.addEventListener("orientationchange", () => setTimeout(fitCanvas, 100));

  function connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    socket = new WebSocket(proto + "//" + location.host + "/ws");
    socket.binaryType = "arraybuffer";

    socket.onopen = () => {
      reconnectDelay = 500;
      setStatus("live", "Live");
      createDecoder();
      sendSettings();
    };

    socket.onmessage = (event) => {
      if (typeof event.data === "string") { handleControl(event.data); return; }
      handleFrame(new Uint8Array(event.data));
    };

    socket.onclose = () => {
      setStatus("dead", "Disconnected");
      showMessage(
        "Broadcast ended",
        "Reconnecting automatically. If you stopped the broadcast, restart it from " +
        "Control Centre on the sending device."
      );
      scheduleReconnect();
    };

    socket.onerror = () => { try { socket.close(); } catch (_) {} };
  }

  function scheduleReconnect() {
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 5000);
  }

  function handleFrame(bytes) {
    if (bytes.length <= HEADER_BYTES || bytes[0] !== MAGIC) return;
    const isKey = (bytes[2] & FLAG_KEYFRAME) !== 0;

    // Byte 3 carries the sender's rotation; re-fit only when it actually changes so the
    // layout is not recomputed for every frame.
    const incoming = (bytes[3] & 0x03) * 90;
    if (incoming !== rotation) {
      rotation = incoming;
      fitCanvas();
    }

    const timestampMs =
      (bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7]) >>> 0;

    if (!sawKeyframe) {
      if (!isKey) return;
      sawKeyframe = true;
    }
    if (!decoder || decoder.state !== "configured") return;

    bytesSinceTick += bytes.length;
    try {
      decoder.decode(new EncodedVideoChunk({
        type: isKey ? "key" : "delta",
        timestamp: timestampMs * 1000, // WebCodecs timestamps are microseconds.
        data: bytes.subarray(HEADER_BYTES),
      }));
    } catch (err) {
      console.warn("decode failed", err);
      createDecoder();
    }
  }

  function handleControl(text) {
    let msg;
    try { msg = JSON.parse(text); } catch (_) { return; }
    if (msg.kind !== "hello") return;
    document.title = msg.body.deviceName + " · Screen Mirror";
    if (msg.body.settings) {
      document.getElementById("quality").value = String(msg.body.settings.longEdge);
      document.getElementById("fps").value = String(msg.body.settings.fps);
    }
  }

  function sendSettings() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    const longEdge = parseInt(document.getElementById("quality").value, 10);
    const fps = parseInt(document.getElementById("fps").value, 10);
    // Scale the bitrate with the pixel count so 1080p is not starved at 720p's budget.
    const bitrateKbps = Math.round((longEdge / 1280) * (longEdge / 1280) * 3000);
    socket.send(JSON.stringify({
      kind: "configure",
      body: { settings: { longEdge, fps, bitrateKbps } },
    }));
  }

  document.getElementById("quality").addEventListener("change", sendSettings);
  document.getElementById("fps").addEventListener("change", sendSettings);

  document.getElementById("fullscreen").addEventListener("click", () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.();
  });

  // Tap or move the pointer to reveal the controls; they fade out while monitoring so
  // nothing sits on top of the image you are judging.
  let hideTimer = null;
  function revealChrome() {
    chrome.classList.remove("hidden");
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => chrome.classList.add("hidden"), 3000);
  }
  ["pointermove", "pointerdown", "keydown"].forEach((event) =>
    window.addEventListener(event, revealChrome)
  );
  revealChrome();

  setInterval(() => {
    const mbps = (bytesSinceTick * 8 / 1e6).toFixed(1);
    statsEl.textContent =
      canvas.width && canvas.height
        ? `${canvas.width}×${canvas.height} · ${framesSinceTick} fps · ${mbps} Mb/s`
        : "—";
    framesSinceTick = 0;
    bytesSinceTick = 0;
  }, 1000);

  setStatus("", "Connecting");
  connect();
})();
</script>
</body>
</html>
"""#
}
