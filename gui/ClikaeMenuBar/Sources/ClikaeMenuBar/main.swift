// main.swift — Clikae menu bar app.
//
// A menu-bar-only agent (NSStatusItem). The menu is rebuilt on open from the
// clikae CLI: profiles grouped by CLI, the active one check-marked, click to
// launch, and a per-CLI "Relay" submenu for handing a session to another
// profile. Everything routes through the CLI — this app holds no profile state.

import AppKit

// Reference-type payloads for NSMenuItem.representedObject.
final class LaunchSpec { let p: Profile; init(_ p: Profile) { self.p = p } }
final class RelaySpec {
    let cli: String, from: String, to: String
    init(cli: String, from: String, to: String) { self.cli = cli; self.from = from; self.to = to }
}

/// Opens a terminal window running a clikae command. Prefers Ghostty (the
/// maintainer's terminal); falls back to Terminal.app via AppleScript.
enum Launcher {
    static var ghosttyInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Ghostty.app")
            || fm.fileExists(atPath: NSHomeDirectory() + "/Applications/Ghostty.app")
    }

    static func openTerminal(running command: String) {
        if ghosttyInstalled {
            // open -na Ghostty.app --args -e /bin/zsh -lc "<command>"
            spawn("/usr/bin/open",
                  ["-na", "Ghostty.app", "--args", "-e", "/bin/zsh", "-lc", command])
        } else {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
            spawn("/usr/bin/osascript",
                  ["-e", "tell application \"Terminal\" to do script \"\(escaped)\""])
        }
    }

    private static func spawn(_ path: String, _ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        try? proc.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "ｷﾘ"
            button.toolTip = "clikae — CLI profile switcher"
        }
        let menu = NSMenu()
        menu.delegate = self          // rebuild each time it opens
        statusItem.menu = menu
        rebuild(menu)
    }

    // Rebuild on every open so it reflects the current profiles/active state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let profiles: [Profile]
        let active: [String: String]
        do {
            profiles = try Clikae.listProfiles()
            active = (try? Clikae.status()) ?? [:]
        } catch {
            let item = NSMenuItem(title: "clikae: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            addQuit(menu)
            return
        }

        if profiles.isEmpty {
            let item = NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Group by CLI, preserving sorted order.
        let clis = Array(Set(profiles.map { $0.cli })).sorted()
        for cli in clis {
            let header = NSMenuItem(title: cli, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let mine = profiles.filter { $0.cli == cli }.sorted { $0.profile < $1.profile }
            let activeProfile = active[cli]
            for p in mine {
                let item = NSMenuItem(title: "  \(p.profile)",
                                      action: #selector(launch(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = LaunchSpec(p)
                if p.profile == activeProfile { item.state = .on }
                menu.addItem(item)
            }

            // Relay submenu: hand the active session to another profile.
            if let from = activeProfile, mine.contains(where: { $0.profile == from }), mine.count >= 2 {
                let relayItem = NSMenuItem(title: "  Relay \(from) → …", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for p in mine where p.profile != from {
                    let sub = NSMenuItem(title: p.profile,
                                         action: #selector(relay(_:)),
                                         keyEquivalent: "")
                    sub.target = self
                    sub.representedObject = RelaySpec(cli: cli, from: from, to: p.profile)
                    submenu.addItem(sub)
                }
                relayItem.submenu = submenu
                menu.addItem(relayItem)
            }

            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        addQuit(menu)
    }

    private func addQuit(_ menu: NSMenu) {
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func launch(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? LaunchSpec else { return }
        Launcher.openTerminal(running: "clikae run \(spec.p.cli) \(spec.p.profile)")
    }

    @objc private func relay(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? RelaySpec else { return }
        Launcher.openTerminal(running: "clikae relay \(spec.cli) \(spec.from) \(spec.to)")
    }

    @objc private func refresh(_ sender: NSMenuItem) {
        if let menu = statusItem.menu { rebuild(menu) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
