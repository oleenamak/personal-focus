import AppKit
import WebKit

// Personal Focus: a small transparent desktop window that hosts the typewriter UI.
// All logic lives in Sources/Core. This file only wires the window, the web view and the menu.
//
// Launch options (used for testing so the real log and recovery file are never touched):
//   --state-dir <dir>   where state.json lives
//   --log-dir <dir>     the daily log folder
//   --e2e <dir>         run a scripted UI walkthrough, save screenshots into <dir>, then quit

final class FocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: FocusWindow!
    var web: WKWebView!
    var engine: Engine!
    var timer: Timer?
    var e2eDir: URL?

    func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Personal Focus")
        let stateDir = arg("--state-dir").map { URL(fileURLWithPath: $0) } ?? support
        let defaultLogs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Personal LLM Wiki/Work Log")
        let logDir = arg("--log-dir").map { URL(fileURLWithPath: $0) } ?? defaultLogs
        e2eDir = arg("--e2e").map { URL(fileURLWithPath: $0) }
        engine = Engine(clock: SystemClock(), stateURL: stateDir.appendingPathComponent("state.json"), defaultFolder: logDir)
        if arg("--log-dir") != nil { engine.setLogFolder(logDir) }

        buildMenu()
        buildWindow()
        flush()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.systemWillSleep(); self?.push()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.engine.tick()
            if self.engine.hasActive { self.push() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func flush() { engine.flush(); push() }

    func applicationWillTerminate(_ notification: Notification) { engine.appWillQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }

    // MARK: Window

    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "pf")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self

        window = FocusWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 460)
        window.contentView = web
        if arg("--e2e") != nil {
            window.setFrame(NSRect(x: 80, y: 80, width: 520, height: 700), display: true)     // scripted runs never save the frame
        } else {
            window.setFrameAutosaveName("PersonalFocusWindow")
            if !window.setFrameUsingName("PersonalFocusWindow") { window.center() }
        }
        window.makeKeyAndOrderFront(nil)

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("index.html")
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../ui/index.html").standardized
        let ui = (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? dev
        web.loadFileURL(ui, allowingReadAccessTo: ui.deletingLastPathComponent())
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Personal Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // MARK: Bridge

    func push() {
        guard web != nil, let data = try? JSONSerialization.data(withJSONObject: engine.snapshot()),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.pfRender && window.pfRender(\(json))", completionHandler: nil)
    }

    func reply(_ cmd: String, _ error: Error?) {
        let payload: [String: Any] = ["cmd": cmd, "ok": error == nil, "error": error?.localizedDescription ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
            web.evaluateJavaScript("window.pfResult && window.pfResult(\(json))", completionHandler: nil)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return }
        let s = { (k: String) -> String in (m[k] as? String) ?? "" }
        var err: Error?
        switch cmd {
        case "ready": push(); return
        case "moveBy":
            var f = window.frame
            f.origin.x += CGFloat((m["dx"] as? Double) ?? 0)
            f.origin.y -= CGFloat((m["dy"] as? Double) ?? 0)      // screen y grows downward, Cocoa's grows upward
            window.setFrame(f, display: true)
            return
        case "resizeBy":
            let f = window.frame
            let room = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 4000, height: 4000)
            let w = min(max(f.width + CGFloat((m["dw"] as? Double) ?? 0), window.minSize.width), room.width)
            let h = min(max(f.height + CGFloat((m["dh"] as? Double) ?? 0), window.minSize.height), room.height)
            window.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: w, height: h), display: true)   // keep the top-left corner fixed
            return
        case "frame":
            FileHandle.standardError.write(Data("[frame] \(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))\n".utf8))
            return
        case "addTask": do { try engine.addTask(s("text")) } catch { err = error }
        case "start": do { try engine.start(s("id")) } catch { err = error }
        case "pause": engine.pause()
        case "resume": engine.resume()
        case "stop": do { try engine.stop() } catch EngineError.noActiveSession { } catch { err = error }
        case "complete": do { try engine.complete(s("id"), note: s("note"), workType: s("workType")) } catch EngineError.taskNotFound { } catch { err = error }
        case "retro":
            do { try engine.logFinished(text: s("text"), date: s("date"), minutes: s("minutes"), note: s("note"),
                                        workType: s("workType"), opId: s("opId")) } catch { err = error }
        case "retry": engine.retry()
        case "dismissNotice": engine.notice = nil
        case "chooseFolder": chooseFolder()
        default: return
        }
        reply(cmd == "retro" ? "retro" : cmd, err)
        push()
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = engine.logFolder.deletingLastPathComponent()
        p.prompt = "Use this folder"
        p.message = "Choose the folder where daily work logs are saved."
        if p.runModal() == .OK, let url = p.url { engine.setLogFolder(url) }
    }

    // MARK: Scripted walkthrough (--e2e)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        push()
        if let dir = e2eDir { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.runE2E(dir) } }
    }

    func runE2E(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func addTask(_ t: String) -> String {
            "(function(){var i=document.getElementById('inp');i.value=\(jsString(t));i.dispatchEvent(new Event('input'));i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'}))})()"
        }
        let steps: [(Double, String)] = [
            (0.0, addTask("Outline this week's article")),
            (0.5, addTask("Apply to 3 companies")),
            (0.5, addTask("Interview prep")),
            (1.2, "document.querySelectorAll('.line .play')[0].click()"),
            (2.4, "document.getElementById('pause').click()"),
            (1.2, "document.getElementById('pause').click()"),
            (1.2, "SNAP:e2e-1-running"),
            (0.3, "document.getElementById('stop').click()"),
            (0.6, "var l=document.querySelectorAll('.line')[1];var c=l.querySelector('.chk');c.checked=true;c.dispatchEvent(new Event('change'));l.querySelector('.note').value='Sent 3 applications';l.querySelector('.wt').value='Independent work'"),
            (0.1, "PRINT:(function(){var l=document.querySelectorAll('.line')[1];var s=l.querySelector('.slip');var cs=getComputedStyle(l);return l.className+' lineH='+l.offsetHeight+' slipH='+s.offsetHeight+' maxH='+cs.maxHeight+' trans='+cs.transitionProperty+'/'+cs.transitionDuration+' vis='+document.visibilityState+' rules='+Array.from(document.styleSheets[0].cssRules).filter(function(r){return r.selectorText&&r.selectorText.indexOf('.open')>-1}).map(function(r){return r.cssText}).join('|')})()"),
            (0.6, "SNAP:e2e-2-completing"),
            (0.2, "document.querySelectorAll('.line')[1].querySelector('.ok').click()"),
            (0.4, "document.getElementById('retro').click()"),
            (0.3, "document.getElementById('rt').value='Booked hair appointment';document.getElementById('rm').value='12';document.getElementById('rn').value='Quick one'"),
            (0.5, "SNAP:e2e-3-retro-form"),
            (0.1, "document.getElementById('rm').value='abc';document.getElementById('rgo').click()"),
            (0.5, "SNAP:e2e-3b-retro-error"),
            (0.1, "document.getElementById('rm').value='12';document.getElementById('rgo').click()"),
            (1.8, "SNAP:e2e-4-after"),
            (0.1, "FRAME"),
            (0.1, "var f=function(t,x,y){var e=new MouseEvent(t,{screenX:x,screenY:y,bubbles:true});(t==='mousedown'?document.getElementById('tw'):window).dispatchEvent(e)};f('mousedown',500,500);f('mousemove',560,470);f('mousemove',620,440);f('mouseup',620,440)"),
            (0.3, "FRAME"),
            (0.1, "var g=function(t,x,y){var e=new MouseEvent(t,{screenX:x,screenY:y,bubbles:true});(t==='mousedown'?document.getElementById('grip'):window).dispatchEvent(e)};g('mousedown',900,900);g('mousemove',960,940);g('mouseup',960,940)"),
            (0.3, "FRAME"),
            (0.1, "var h=function(t,x,y){var e=new MouseEvent(t,{screenX:x,screenY:y,bubbles:true});(t==='mousedown'?document.getElementById('grip'):window).dispatchEvent(e)};h('mousedown',900,900);h('mousemove',100,100);h('mouseup',100,100)"),
            (0.3, "FRAME"),
            (0.4, "DONE"),
        ]
        func run(_ i: Int) {
            guard i < steps.count else { return }
            let (delay, js) = steps[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let a = self.engine.snapshot()["active"]
                FileHandle.standardError.write(Data("[e2e \(i) t=\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) active=\(a ?? "nil")] \(js.prefix(60))\n".utf8))
                if js == "FRAME" { self.web.evaluateJavaScript("window.webkit.messageHandlers.pf.postMessage({cmd:'frame'})") { _, _ in run(i + 1) }; return }
                if js == "DONE" { self.engine.appWillQuit(); NSApp.terminate(nil); return }
                if js.hasPrefix("PRINT:") {
                    self.web.evaluateJavaScript(String(js.dropFirst(6))) { r, e in
                        FileHandle.standardError.write(Data("[e2e print] \(r ?? e ?? "nil")\n".utf8)); run(i + 1)
                    }
                    return
                }
                if js.hasPrefix("SNAP:") { self.snapshot(dir.appendingPathComponent(String(js.dropFirst(5)))) { run(i + 1) }; return }
                self.web.evaluateJavaScript(js) { _, _ in run(i + 1) }
            }
        }
        run(0)
    }

    func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        let t = String(data: d, encoding: .utf8)!
        return String(t.dropFirst().dropLast())
    }

    func snapshot(_ base: URL, done: @escaping () -> Void) {
        web.takeSnapshot(with: nil) { image, _ in
            guard let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { done(); return }
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("png"))
            // Same image on a plain desktop-coloured backdrop so the transparent window is easy to review.
            let bg = NSImage(size: img.size)
            bg.lockFocus()
            NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.55, alpha: 1).setFill()
            NSRect(origin: .zero, size: img.size).fill()
            img.draw(in: NSRect(origin: .zero, size: img.size))
            bg.unlockFocus()
            if let t2 = bg.tiffRepresentation, let r2 = NSBitmapImageRep(data: t2) {
                try? r2.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("on-desktop.png"))
            }
            done()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
