// Phone as a Mac trackpad.
//
// `getevent` streams the touchscreen's raw driver events over adb — before
// Android's UI ever sees them — so we can read finger positions directly and
// turn them into Mac cursor movement, clicks and scrolling.

import Cocoa

/// A black page the phone shows while acting as a trackpad. It swallows every
/// gesture, so touches land on nothing while the Mac reads them underneath.
let trackpadSurfaceHTML = """
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no,viewport-fit=cover">
<title>Trackpad</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden;
            overscroll-behavior:none;touch-action:none;
            -webkit-user-select:none;user-select:none;
            font:500 15px -apple-system,Roboto,sans-serif}
  #m{position:fixed;inset:0;display:grid;place-items:center;text-align:center;line-height:2}
  b{display:block;color:#6a6a6f;font-weight:600;letter-spacing:.03em}
  i{font-style:normal;font-size:13px;color:#333338}
  .dot{width:7px;height:7px;border-radius:50%;background:#d62828;margin:16px auto 0;opacity:.85}
  #m.go b,#m.go i{opacity:.22;transition:opacity .6s}
  #kb{position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;border:0;padding:0;
      background:transparent;color:transparent;caret-color:transparent}
  #hint{position:fixed;left:0;right:0;bottom:24px;text-align:center;color:#d62828;
        font-size:13px;letter-spacing:.04em;opacity:0;transition:opacity .3s}
  #hint.on{opacity:.9}
</style>
<div id="m"><div>
  <b>Trackpad</b>
  <i>drag &middot; tap &middot; two fingers scroll<br>three fingers switch desktop</i>
  <div class="dot"></div>
</div></div>
<input id="kb" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
<div id="hint">typing to your Mac</div>
<script>
// Gesture recognition happens here, not on the Mac: the browser reports every
// finger reliably, while the phone's input driver only ever reports one.
const send = (p) => { fetch(p, {cache:'no-store', keepalive:true}).catch(()=>{}); };

const kb = document.getElementById('kb'), hint = document.getElementById('hint');
let pending = {x:0, y:0}, flushQueued = false;
function queueMove(dx, dy) {
  pending.x += dx; pending.y += dy;
  if (flushQueued) return;
  flushQueued = true;
  requestAnimationFrame(() => {
    flushQueued = false;
    const {x, y} = pending; pending = {x:0, y:0};
    if (Math.abs(x) > 0.2 || Math.abs(y) > 0.2)
      send(`/m?x=${x.toFixed(1)}&y=${y.toFixed(1)}`);
  });
}

const SWIPE = 70, TAP_MS = 250, TAP_SLOP = 12, HOLD_MS = 450;
let start = null, last = null, maxFingers = 0, moved = 0;
let fired = false, dragging = false, holdTimer = null, lastTapAt = 0;

const centroid = (t) => {
  let x = 0, y = 0;
  for (const p of t) { x += p.clientX; y += p.clientY; }
  return {x: x / t.length, y: y / t.length};
};

document.addEventListener('touchstart', e => {
  if (e.target !== kb) e.preventDefault();
  const c = centroid(e.touches);
  if (e.touches.length > maxFingers) maxFingers = e.touches.length;
  if (!start) { start = c; moved = 0; fired = false; }
  last = c;
  clearTimeout(holdTimer);
  if (e.touches.length === 1) {
    holdTimer = setTimeout(() => {
      if (moved < TAP_SLOP && maxFingers === 1) { dragging = true; send('/d?s=1'); }
    }, HOLD_MS);
  }
}, {passive:false});

document.addEventListener('touchmove', e => {
  if (e.target !== kb) e.preventDefault();
  const c = centroid(e.touches), n = e.touches.length;
  if (!last) { last = c; return; }
  const dx = c.x - last.x, dy = c.y - last.y;
  last = c;
  moved += Math.abs(dx) + Math.abs(dy);

  if (n === 1) { queueMove(dx, dy); return; }
  if (n === 2) { send(`/s?y=${(-dy).toFixed(1)}`); return; }

  // Three or more: one desktop switch per gesture.
  if (fired || !start) return;
  const tx = c.x - start.x, ty = c.y - start.y;
  if (Math.abs(tx) > SWIPE && Math.abs(tx) > Math.abs(ty)) {
    fired = true; send('/g?n=' + (tx < 0 ? 'sr' : 'sl'));
  } else if (-ty > SWIPE) { fired = true; send('/g?n=mc'); }
  else if (ty > SWIPE)    { fired = true; send('/g?n=ae'); }
}, {passive:false});

document.addEventListener('touchend', e => {
  if (e.target !== kb) e.preventDefault();
  if (e.touches.length > 0) { last = centroid(e.touches); return; }

  clearTimeout(holdTimer);
  const held = performance.now() - (startedAt || 0);
  if (dragging) { dragging = false; send('/d?s=0'); }
  else if (!fired && moved < TAP_SLOP && held < TAP_MS) {
    const now = performance.now();
    const dbl = now - lastTapAt < 320;
    lastTapAt = dbl ? 0 : now;
    if (maxFingers >= 2) send('/c?b=r&n=1');
    else send('/c?b=l&n=' + (dbl ? 2 : 1));
  }
  start = null; last = null; maxFingers = 0; moved = 0; fired = false;
}, {passive:false});

let startedAt = 0;
document.addEventListener('touchstart', () => { if (!startedAt || !start) startedAt = performance.now(); }, {passive:true});
document.addEventListener('touchend', e => { if (e.touches.length === 0) startedAt = 0; }, {passive:true});

document.addEventListener('pointerdown', () => {
  document.documentElement.requestFullscreen?.().catch(()=>{});
  document.getElementById('m').classList.add('go');
}, {once:true});

kb.addEventListener('input', () => {
  const v = kb.value;
  if (v) { send('/k?c=' + encodeURIComponent(v)); kb.value = ''; }
});
kb.addEventListener('keydown', e => {
  const map = {Backspace:'back', Enter:'enter', Tab:'tab', Escape:'esc'};
  if (map[e.key]) { send('/sp?k=' + map[e.key]); e.preventDefault(); }
});

setInterval(async () => {
  try {
    const s = await (await fetch('/state', {cache:'no-store'})).json();
    if (s.kb) { hint.classList.add('on'); if (document.activeElement !== kb) kb.focus(); }
    else { hint.classList.remove('on'); if (document.activeElement === kb) kb.blur(); }
  } catch (e) {}
}, 500);
</script>
"""

final class Trackpad {
    static let shared = Trackpad()

    private var focusTimer: Timer?
    private(set) var running = false
    private var lastTarget: String?


    /// Start listening regardless of adb. If a device happens to be reachable we
    /// also open the app for convenience, but the phone can dial in unaided.
    func startServers(target: String?) {
        guard !running else { return }
        guard AXIsProcessTrusted() else {
            let a = NSAlert()
            a.messageText = "Accessibility permission needed"
            a.informativeText = """
            To move the Mac's cursor, Phone Control needs Accessibility access.

            System Settings → Privacy & Security → Accessibility → enable Phone Control, then turn the trackpad on again.
            """
            a.alertStyle = .warning
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        lastTarget = target
        SurfaceServer.shared.start()
        CommandServer.shared.start()
        Discovery.shared.start()
        running = true

        guard let target else { return }
        DispatchQueue.global().async { [weak self] in
            guard let ip = self?.macIP() else { return }
            adb(["-s", target, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 6)
            adb(["-s", target, "shell",
                "am start -n com.gaurav.touchremote/.MainActivity --es host \(ip)"], timeout: 12)
        }

        DispatchQueue.main.async { [weak self] in
            self?.focusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                SurfaceServer.shared.wantsKeyboard = macFocusIsTextInput()
            }
        }
    }

    func stop() {
        running = false
        SurfaceServer.shared.stop()
        CommandServer.shared.stop()
        focusTimer?.invalidate(); focusTimer = nil
        if let t = lastTarget, !t.isEmpty {
            adb(["-s", t, "shell", "input", "keyevent", "KEYCODE_HOME"], timeout: 6)
        }
    }

    /// The Mac's address on the same network as the phone.
    private func macIP() -> String? {
        for line in sh("/sbin/ifconfig", [], timeout: 6).split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("inet "), !l.contains("127.0.0.1") else { continue }
            let addr = String(l.dropFirst(5).prefix(while: { $0 != " " }))
            if addr.hasPrefix("192.168.") || addr.hasPrefix("10.") || addr.hasPrefix("172.") { return addr }
        }
        return nil
    }
}
