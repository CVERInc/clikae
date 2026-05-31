// Clikae.swift — a thin wrapper around the `clikae` CLI.
//
// The CLI is the source of truth (see gui/README.md). This type only runs it and
// parses its human-readable output; it never reimplements profile-store logic.

import Foundation

/// One (CLI, profile) pair as reported by `clikae list`.
struct Profile: Hashable {
    let cli: String
    let profile: String
    let path: String
}

/// Which profile a CLI is currently on, per `clikae status` (this shell's view).
struct ActiveStatus {
    let cli: String
    let active: String   // profile name, or "(default)" / "(external)"
}

enum ClikaeError: Error, CustomStringConvertible {
    case notFound
    case failed(String)
    var description: String {
        switch self {
        case .notFound: return "clikae CLI not found on PATH"
        case .failed(let m): return m
        }
    }
}

enum Clikae {
    /// Run `clikae <args>` through a login shell so the user's PATH (Homebrew,
    /// etc.) is available — GUI apps don't inherit a terminal's PATH. Returns
    /// stdout; throws on non-zero exit.
    @discardableResult
    static func run(_ args: [String]) throws -> String {
        // Quote each arg defensively. clikae names are restricted to
        // [A-Za-z0-9._-], but paths passed via --out etc. may contain spaces.
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "clikae " + quoted.joined(separator: " ")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
        } catch {
            throw ClikaeError.notFound
        }
        proc.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            let msg = stderr.isEmpty ? stdout : stderr
            if msg.localizedCaseInsensitiveContains("command not found") {
                throw ClikaeError.notFound
            }
            throw ClikaeError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// Split a clikae table row on runs of 2+ spaces (the column gap). clikae
    /// names never contain spaces, so the first columns split cleanly.
    private static func columns(_ line: String) -> [String] {
        return line
            .components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `clikae list -p` → profiles. Skips the header row.
    static func listProfiles() throws -> [Profile] {
        let output = try run(["list", "-p"])
        var result: [Profile] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = columns(String(line))
            guard cols.count >= 3 else { continue }
            if cols[0] == "CLI" && cols[1] == "PROFILE" { continue }  // header
            if cols[0].localizedCaseInsensitiveContains("No profiles") { continue }
            result.append(Profile(cli: cols[0], profile: cols[1], path: cols[2]))
        }
        return result
    }

    /// `clikae status` → active profile per CLI in this process's shell.
    static func status() throws -> [String: String] {
        let output = try run(["status"])
        var map: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = columns(String(line))
            guard cols.count >= 2 else { continue }
            if cols[0] == "CLI" { continue }
            map[cols[0]] = cols[1]
        }
        return map
    }
}
