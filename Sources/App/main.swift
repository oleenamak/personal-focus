import AppKit
import WebKit

// Personal Focus: a small transparent desktop window (a folder and today's note) hosted in a web view.
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
    var statusItem: NSStatusItem?

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

        NSApp.applicationIconImage = appIcon()
        buildMenu()
        buildWindow()
        buildStatusItem()
        flush()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.systemWillSleep(); self?.push()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.engine.tick()
            if self.engine.hasActive { self.push() }
            self.updateStatusItem()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func flush() { engine.flush(); push() }

    func applicationWillTerminate(_ notification: Notification) { engine.appWillQuit() }
    // Closing the window only hides it. The timer keeps running until the app is quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideWindow() { window.orderOut(nil) }

    @objc func toggleWindow() { window.isVisible ? hideWindow() : showWindow() }

    // MARK: Menu bar timer

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleWindow)
        item.button?.toolTip = "Personal Focus"
        statusItem = item
        updateStatusItem()
    }

    func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        if engine.hasActive {
            let secs = Int(engine.activeSeconds().rounded())
            b.image = NSImage(systemSymbolName: engine.isRunning ? "clock" : "pause.circle", accessibilityDescription: "Timer")
            b.title = " " + clockString(secs)
            b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.imagePosition = .imageLeft
        } else {
            b.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Personal Focus")
            b.title = ""
        }
    }

    func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            let back = NSBezierPath(roundedRect: NSRect(x: 56, y: 92, width: 400, height: 300), xRadius: 40, yRadius: 40)
            NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.88, alpha: 1).setFill(); back.fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 96, y: 150, width: 320, height: 210), xRadius: 22, yRadius: 22).fill()
            NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.46, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 96, y: 310, width: 320, height: 50), xRadius: 22, yRadius: 22).fill()
            let front = NSBezierPath(roundedRect: NSRect(x: 56, y: 72, width: 400, height: 190), xRadius: 40, yRadius: 40)
            NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.99, alpha: 1),
                       ending: NSColor(calibratedRed: 0.16, green: 0.56, blue: 0.90, alpha: 1))?.draw(in: front, angle: -90)
            return true
        }
    }

    // MARK: Window

    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "pf")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self

        window = FocusWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = web
        if arg("--e2e") != nil {
            window.setFrame(NSRect(x: 80, y: 80, width: 340, height: 360), display: true)     // scripted runs never save the frame
        } else {
            window.setFrameAutosaveName("PersonalFocusFolder")
            if !window.setFrameUsingName("PersonalFocusFolder") { window.center() }
            var f = window.frame; f.size = NSSize(width: 340, height: 360); window.setFrame(f, display: true)   // fixed size
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
        let close = appMenu.addItem(withTitle: "Close Window", action: #selector(hideWindow), keyEquivalent: "w")
        close.target = self
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
        case "hide": hideWindow(); return
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
            "(function(){var i=document.getElementById('newt');i.value=\(jsString(t));i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'}))})()"
        }
        let drag = "var f=function(t,x,y){var e=new MouseEvent(t,{screenX:x,screenY:y,bubbles:true});(t==='mousedown'?document.getElementById('%@'):window).dispatchEvent(e)};f('mousedown',500,500);f('mousemove',560,470);f('mousemove',620,440);f('mouseup',620,440)"
        let steps: [(Double, String)] = [
            (0.0, "SNAP:e2e-0-folder"),
            (0.1, "document.getElementById('art').click()"),
            (0.7, addTask("Outline this week's article")),
            (0.5, addTask("Apply to 3 companies")),
            (0.5, addTask("Interview prep")),
            (1.2, "document.querySelectorAll('[data-act=start]')[0].click()"),
            (2.4, "document.querySelector('[data-act=pp]').click()"),
            (1.2, "document.querySelector('[data-act=pp]').click()"),
            (1.2, "SNAP:e2e-1-running"),
            (0.2, "document.querySelector('[data-act=stop]').click()"),
            (0.6, "document.querySelectorAll('[data-act=comp]')[1].click()"),
            (0.4, "document.getElementById('cn').value='Sent 3 applications';document.getElementById('cy').value='Independent work'"),
            (0.5, "SNAP:e2e-2-completing"),
            (0.2, "document.querySelector('[data-act=done]').click()"),
            (0.4, "document.getElementById('retrob').click()"),
            (0.3, "document.getElementById('rt').value='Booked hair appointment';document.getElementById('rm').value='12';document.getElementById('rn').value='Quick one'"),
            (0.5, "SNAP:e2e-3-retro-form"),
            (0.1, "document.getElementById('rm').value='abc';document.getElementById('rgo').click()"),
            (0.5, "SNAP:e2e-3b-retro-error"),
            (0.1, "document.getElementById('rm').value='12';document.getElementById('rgo').click()"),
            (1.8, "SNAP:e2e-4-after"),
            (0.1, "FRAME"),
            (0.1, String(format: drag, "nh")),
            (0.3, "FRAME"),
            (0.1, "PRINT:'open after header drag = ' + document.getElementById('win').classList.contains('o')"),
            (0.1, "document.getElementById('collapse').click()"),
            (0.7, "PRINT:'closed = ' + !document.getElementById('win').classList.contains('o')"),
            (0.1, String(format: drag, "art")),
            (0.3, "FRAME"),
            (0.1, "PRINT:'open after folder drag (should stay closed) = ' + document.getElementById('win').classList.contains('o')"),
            (0.3, "SNAP:e2e-5-closed-running-none"),
            (0.1, "document.querySelectorAll('[data-act=start]')[0].click()"),
            (1.3, "STATUS"),
            (0.1, "HIDE"),
            (2.2, "STATUS"),
            (0.1, "SHOW"),
            (0.4, "STATUS"),
            (0.1, "document.querySelector('[data-act=stop]').click()"),
            (0.4, "DONE"),
        ]
        func run(_ i: Int) {
            guard i < steps.count else { return }
            let (delay, js) = steps[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let a = self.engine.snapshot()["active"]
                FileHandle.standardError.write(Data("[e2e \(i) t=\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) active=\(a ?? "nil")] \(js.prefix(60))\n".utf8))
                if js == "FRAME" { self.web.evaluateJavaScript("window.webkit.messageHandlers.pf.postMessage({cmd:'frame'})") { _, _ in run(i + 1) }; return }
                if js == "HIDE" { self.hideWindow(); FileHandle.standardError.write(Data("[hide] visible=\(self.window.isVisible) timerActive=\(self.engine.hasActive) status=\(self.statusItem?.button?.title ?? "nil")\n".utf8)); run(i + 1); return }
                if js == "STATUS" { FileHandle.standardError.write(Data("[status] window.visible=\(self.window.isVisible) timerSeconds=\(Int(self.engine.activeSeconds().rounded())) menubar=\"\(self.statusItem?.button?.title ?? "nil")\"\n".utf8)); run(i + 1); return }
                if js == "SHOW" { self.showWindow(); FileHandle.standardError.write(Data("[show] visible=\(self.window.isVisible)\n".utf8)); run(i + 1); return }
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
