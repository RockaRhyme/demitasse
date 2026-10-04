import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var caffeinate: Process?
    private var until: Date?  // when a timed session ends; nil when on indefinitely
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let displaySwitch = MenuSwitch()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var usage: [AccountUsage] = []
    private var usageFetched: Date?
    private var isFetchingUsage = false
    private var usageEpoch = 0  // bumped when a reset is redeemed, so older fetches are discarded
    private var isRedeeming = false
    private let usageTag = 100

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(toggleItem)
        // A row of buttons rather than a submenu: submenus open in the wrong place once
        // the usage rows are inserted.
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
        let label = NSTextField(labelWithString: "Keep awake")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview(label)
        // Tag is the duration in hours; 0 means no time limit, -1 turns it off.
        for (title, hours) in [("1h", 1), ("4h", 4), ("8h", 8), ("16h", 16), ("1d", 24), ("1w", 168), ("∞", 0), ("Off", -1)] {
            let button = NSButton(title: title, target: self, action: #selector(turnOnFor(_:)))
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.tag = hours
            row.addArrangedSubview(button)
        }
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        let timed = NSMenuItem()
        timed.view = row
        menu.addItem(timed)
        let displayRow = NSStackView()
        displayRow.orientation = .horizontal
        displayRow.spacing = 6
        displayRow.edgeInsets = row.edgeInsets
        let displayLabel = NSTextField(labelWithString: "Keep display awake")
        displayLabel.font = label.font
        displayLabel.textColor = label.textColor
        displayRow.addArrangedSubview(displayLabel)
        displaySwitch.target = self
        displaySwitch.action = #selector(toggleDisplay)
        displaySwitch.setAccessibilityLabel("Keep display awake")
        displayRow.addArrangedSubview(displaySwitch)
        displayRow.frame = NSRect(origin: .zero, size: displayRow.fittingSize)
        let display = NSMenuItem()
        display.view = displayRow
        menu.addItem(display)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        // Launch at login by default, once it has registered; after that the menu item (or
        // System Settings) decides.
        if !UserDefaults.standard.bool(forKey: "loginItemSet"), setLogin(true) {
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        refresh()
    }

    private var isOn: Bool { caffeinate?.isRunning ?? false }

    @objc private func toggleLogin() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else if !setLogin(status != .enabled) {
            NSSound.beep()
        }
    }

    private func setLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Launch at login: %@", error.localizedDescription)
            // Registered but waiting for approval in System Settings: the user decides from here.
            return on && SMAppService.mainApp.status == .requiresApproval
        }
    }

    @objc private func turnOnFor(_ sender: NSButton) {
        statusItem.menu?.cancelTracking()  // buttons in a menu don't close it themselves
        stop()
        if sender.tag >= 0 { start(seconds: sender.tag == 0 ? nil : sender.tag * 3600) }
        refresh()
    }

    // The display stays awake by default; turning this off lets it sleep while the Mac stays awake.
    private var allowDisplaySleep: Bool { UserDefaults.standard.bool(forKey: "allowDisplaySleep") }

    @objc private func toggleDisplay() {
        UserDefaults.standard.set(!allowDisplaySleep, forKey: "allowDisplaySleep")
        if isOn {  // restart the running session with the new setting, keeping its end time
            let left = until.map { max(1, Int($0.timeIntervalSinceNow.rounded())) }
            stop()
            start(seconds: left)
        }
        refresh()
    }

    private func stop() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    private func start(seconds: Int?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // Keep idle, disk and system awake, and the display unless it's allowed to sleep.
        // -w ends the session if the app dies without stopping it.
        p.arguments = [allowDisplaySleep ? "-ims" : "-dims", "-w", String(getpid())]
        if let seconds { p.arguments! += ["-t", String(seconds)] }  // caffeinate exits by itself
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        do {
            try p.run()
            caffeinate = p
            until = seconds.map { Date().addingTimeInterval(Double($0)) }
        } catch { NSSound.beep() }
    }

    private func refresh() {
        let name = isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Caffeinate")
        img?.isTemplate = true
        statusItem.button?.image = img
        var on = "On"
        if isOn, let until {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(until) ? "h:mm a"
                : until.timeIntervalSinceNow < 6 * 86400 ? "EEE h:mm a" : "MMM d, h:mm a"
            on = "On until " + f.string(from: until)
        }
        statusItem.button?.toolTip = isOn ? "Caffeinate: \(on) (staying awake)" : "Caffeinate: OFF"
        toggleItem.title = isOn ? "Caffeinate: \(on)" : "Caffeinate: Off"  // status only; the buttons control it
        toggleItem.state = isOn ? .on : .off
        displaySwitch.isOn = !allowDisplaySleep
    }

    // MARK: AI subscription usage

    func menuWillOpen(_ menu: NSMenu) {
        let login = SMAppService.mainApp.status
        loginItem.state = login == .enabled ? .on : .off
        loginItem.title = login == .requiresApproval ? "Launch at Login — Approve in System Settings…" : "Launch at Login"
        renderUsage(in: menu)
        // Usage endpoints rate-limit aggressively; reuse results for a minute.
        guard usageFetched.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        fetchUsage()
    }

    @MainActor private func fetchUsage() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        let epoch = usageEpoch
        Task {
            let result = await Usage.fetchAll()
            DispatchQueue.main.async {
                self.isFetchingUsage = false
                // A reset was redeemed while this was in flight, so it may predate it; fetch again.
                guard epoch == self.usageEpoch else { return self.fetchUsage() }
                self.usage = result
                self.usageFetched = Date()
                if let menu = self.statusItem.menu { self.renderUsage(in: menu) }
            }
        }
    }

    private func renderUsage(in menu: NSMenu) {
        for item in menu.items where item.tag == usageTag { menu.removeItem(item) }
        var items: [NSMenuItem] = []
        if usage.isEmpty {
            items.append(labelItem(styled(usageFetched == nil ? "Loading AI usage…" : "No AI subscriptions detected", color: .secondaryLabelColor)))
        }
        for account in usage {
            items.append(labelItem(styled(account.title, font: .boldSystemFont(ofSize: 12))))
            for line in usageLines(account, in: usage) { items.append(labelItem(line)) }
            if let next = account.resetCredits.first {
                let count = account.resetCredits.count
                var title = "\(count) banked reset\(count == 1 ? "" : "s")"
                if let expires = next.expires {
                    let f = DateFormatter()
                    f.dateFormat = "MMM d"
                    title += " · next expires " + f.string(from: expires)
                }
                let item = NSMenuItem(title: "", action: isRedeeming ? nil : #selector(useReset(_:)), keyEquivalent: "")
                item.attributedTitle = styled(title + " — Use One…", font: .systemFont(ofSize: 11))
                item.target = self
                item.representedObject = account
                items.append(item)
            }
        }
        items.append(.separator())
        for (offset, item) in items.enumerated() {
            item.tag = usageTag
            menu.insertItem(item, at: 4 + offset)  // below the toggle, timer row, display row and separator
        }
    }

    @MainActor @objc private func useReset(_ sender: NSMenuItem) {
        guard !isRedeeming, let account = sender.representedObject as? AccountUsage, let credit = account.resetCredits.first else { return }
        isRedeeming = true
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Use a banked reset?"
        let current = account.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))% used" }.joined(separator: ", ")
        confirm.informativeText = "\(account.title)\nCurrent usage: \(current.isEmpty ? "unknown" : current)\n\n"
            + "This resets your usage limits now and spends 1 of your \(account.resetCredits.count) banked resets. It can't be undone."
        confirm.addButton(withTitle: "Use Reset")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            isRedeeming = false
            return
        }
        Task {
            let outcome = await Usage.redeemCodexReset(credit.id)
            DispatchQueue.main.async {
                self.isRedeeming = false
                // Drop the credit now and refetch; if it wasn't spent the fresh result restores it.
                self.usageEpoch += 1
                for i in self.usage.indices { self.usage[i].resetCredits.removeAll { $0.id == credit.id } }
                self.fetchUsage()
                let done = NSAlert()
                done.messageText = outcome
                NSApp.activate(ignoringOtherApps: true)
                done.runModal()
            }
        }
    }

    private func labelItem(_ text: NSAttributedString) -> NSMenuItem {
        let field = NSTextField(labelWithAttributedString: text)
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: 14, y: 2))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: field.frame.width + 28, height: field.frame.height + 4))
        view.addSubview(field)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func styled(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { caffeinate?.terminate() }
}

// A small switch drawn by hand: NSSwitch renders gray inside a menu, so on and off look alike.
// It only reports clicks; the owner sets isOn.
final class MenuSwitch: NSControl {
    var isOn = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = bounds.height - 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? bounds.width - size - 2 : 2, y: 2, width: size, height: size)).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
}

// Menu rows for one account, e.g. "5h  ████░░░░░░  42%  resets in 2h 13m".
// Labels are padded to one width across all accounts so the bars line up.
func usageLines(_ account: AccountUsage, in all: [AccountUsage]) -> [NSAttributedString] {
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var lines: [NSAttributedString] = []
    let width = (all.flatMap(\.windows).map(\.label.count).max() ?? 0) + 1
    for w in account.windows {
        let used = min(max(w.usedPercent, 0), 100)
        let filled = Int((used / 10).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
        let color: NSColor = used >= 90 ? .systemRed : used >= 75 ? .systemOrange : .labelColor
        let label = w.label.padding(toLength: width, withPad: " ", startingAt: 0)
        let line = NSMutableAttributedString(string: "\(label) \(bar) " + String(format: "%3d%%", Int(used.rounded())),
                                             attributes: [.font: mono, .foregroundColor: color])
        if let resets = w.resetsAt {
            line.append(NSAttributedString(string: "  " + resetText(resets), attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        lines.append(line)
    }
    if let note = account.note {
        lines.append(NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    return lines
}

func resetText(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "resets now" }
    if seconds < 86400 {
        return seconds < 3600 ? "resets in \(seconds / 60)m" : "resets in \(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
    let f = DateFormatter()
    f.dateFormat = "EEE h:mm a"
    return "resets " + f.string(from: date)
}

// `Demitasse --usage` prints the usage rows and exits, for checking outside the menu.
if CommandLine.arguments.contains("--usage") {
    Task {
        let all = await Usage.fetchAll()
        for account in all {
            print(account.title)
            for line in usageLines(account, in: all) { print("  " + line.string) }
        }
        exit(0)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--login-status") {
    print("launch at login:", SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled (status \(SMAppService.mainApp.status.rawValue))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
