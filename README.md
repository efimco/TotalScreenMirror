# TotalScreenMirror

Mirrors an iPhone or iPad screen to another iPhone, iPad, or any web browser over
local Wi-Fi or a Personal Hotspot. Built as a preview monitor for setting up shots
in the Blackmagic Camera app.

## What it does and does not do

**Does:** mirrors the *whole screen*, so the monitoring device sees the camera app's
overlays — focus peaking, zebras, false colour, framing guides, histogram, record
state — not just a clean feed. Works in a browser, so a laptop or Android tablet can
be the monitor. No accounts, no internet, no pairing.

**Does not:** control the sending device. iOS provides no way to inject touches into
another app, so this is a one-way monitor and always will be.

> **Try Blackmagic's own feature first.** Blackmagic Camera 2.0+ can already monitor
> *and* remotely control other phones running the app over a local network — focus,
> zoom, white balance, shutter, frame rate, synced record start/stop — and an iPad can
> multiview up to nine of them. It works without a Blackmagic Cloud account (look for
> "Use Without Blackmagic Cloud" and enter an IP). If that covers your use, you do not
> need this. This project exists for the two things it does not do: a browser as the
> monitor, and the app's UI overlays rather than the clean feed.

## Setup

Requires **Xcode 26** (App Store) and `xcodegen` (`brew install xcodegen`).

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your Apple
   Developer Team ID in it. Find it in Xcode → Settings → Accounts → your Apple ID →
   your name under "Team"; the 10-character string in parentheses. A free account works.

2. On the phone, enable **Settings → Privacy & Security → Developer Mode**, then
   restart it. Development builds cannot install without this.

3. **Run once from Xcode** (⌘R with the device selected). Only the GUI can bootstrap
   the first development certificate and register the device with your team; the
   command line has nothing to sign with until that exists.

4. From then on, everything is command line:

   ```sh
   make devices                     # find the identifier
   make install DEVICE=<identifier>
   ```

5. On first launch of the **Watch** tab, allow Local Network access. The sending
   device never asks — it only listens, which needs no permission.

With a free account the signature expires after 7 days; rerun `make install`.

### If `actool` fails with "No available simulator runtimes"

CoreSimulator reads the *system-wide* active developer directory, which a fresh
machine often leaves pointing at the Command Line Tools:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

This project ships no asset catalog, so it builds without the fix — but you will
need it before you can add an app icon.

## Using it

**On the shooting device** — open the Send tab, tap Start Mirroring, choose Screen
Mirror, Start Broadcast. (Control Centre's Screen Recording button works too: long
press it and pick Screen Mirror.) The tab shows the address to open, and a QR code.

**On the monitor** — either open the Watch tab and pick the device from the list, or
open `http://<address>:8787` in a browser. Quality and frame rate are set from the
monitor, not the sender.

Works the same when the shooting phone is running Personal Hotspot — the address
will be `172.20.10.1:8787`.

## How it works

```
Shooting device                              Monitor
┌─────────────────────────────┐              ┌──────────────────┐
│ TotalScreenMirror.app       │              │ TotalScreenMirror│
│  · Send tab: picker, QR     │              │  Watch tab       │
│                             │   H.264      │  AVSampleBuffer  │
│ MirrorBroadcast.appex       │───over WS───▶│  DisplayLayer    │
│  · ReplayKit sample buffers │      │       └──────────────────┘
│  · VTPixelTransfer downscale│      │       ┌──────────────────┐
│  · VTCompression H.264      │      └──────▶│ Browser          │
│  · HTTP + WebSocket :8787   │              │ WebCodecs→canvas │
└─────────────────────────────┘              └──────────────────┘
```

Three decisions are worth knowing about, because they are not arbitrary:

**The sender is the server.** Accepting incoming connections needs no Local Network
permission, while making outgoing ones does — and a broadcast extension has no UI to
present a permission prompt in. It also means a browser can just open a URL.

**Congested frames are dropped, not queued.** `WebSocketServer` tracks bytes in
flight and skips clients that are backed up. Buffering would trade a dropped frame
for permanently accumulated delay, which is useless in a monitor.

**Settings live on the viewer.** App Groups is a paid-account capability, so the app
cannot hand configuration to its own extension. The viewer owns quality and frame
rate and pushes them over the same socket.

## Layout

| Path | |
|---|---|
| `Shared/AnnexB.swift` | AVCC ↔ Annex-B, parameter sets, sample buffer assembly |
| `Shared/WireFormat.swift` | 8-byte frame header, control messages, settings |
| `Broadcast/SampleHandler.swift` | ReplayKit entry point |
| `Broadcast/VideoPipeline.swift` | Hardware downscale + H.264 encode |
| `Broadcast/WebSocketServer.swift` | HTTP/1.1 + WebSocket on `NWListener` |
| `Broadcast/ViewerPage.swift` | The browser viewer, served from `/` |
| `App/Send/` | Broadcast picker, address list, QR code |
| `App/View/` | Bonjour discovery, decode, display |

## Troubleshooting

**Nothing in the Watch list.** Bonjour is often blocked on guest and mesh networks.
Type the address from the Send tab instead — the manual field accepts a bare IP or a
pasted `http://…` URL.

**Browser says it can't decode.** The page needs WebCodecs: Safari 16.4+, or a recent
Chrome/Edge/Firefox.

**Black picture in the browser but the UI is visible.** The camera app is marking its
preview as protected content, which ReplayKit captures as black. Nothing can be done
about that from here; use Blackmagic's own remote monitoring instead.

**"Could not start the mirror server."** A previous broadcast is still shutting down
and holding port 8787. Wait a few seconds.

**The phone gets hot.** Expected — you are encoding a second video stream alongside
whatever is recording. Drop to 480p/15fps from the monitor, or treat it as a
setup-time tool rather than a rolling monitor.
