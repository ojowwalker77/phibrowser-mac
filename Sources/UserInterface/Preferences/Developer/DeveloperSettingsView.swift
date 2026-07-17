// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Settings pane content for developer tooling, moved out of the General pane
/// into its own tab: the remote-debugging (CDP) toggle and the lua-browser
/// skill installer. Sections use the shared `SettingsDetailCard` chrome so the
/// pane reads like General's cards. The localized strings keep their original
/// keys from the General pane so existing translations carry over.
struct DeveloperSettingsView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                RemoteDebuggingSectionView()
                SkillInstallSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

/// Section title + content stack, matching the General pane's section layout.
private struct DeveloperSectionView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Remote debugging (CDP)

private struct RemoteDebuggingSectionView: View {
    // Reflects whether the CDP endpoint pref is set. Written through the app's
    // own UserDefaults so the value the launcher reads next start is the one we
    // wrote here (a `defaults write` from another process can lag via cfprefsd).
    @State private var remoteDebuggingEnabled: Bool =
        PhiPreferences.AgentSpaces.remoteDebuggingPort != nil

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Remote debugging", comment: "Developer settings - Remote debugging section title")) {
            SettingsDetailCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Enable remote debugging (CDP)", comment: "Developer settings - Toggle title for the Chrome DevTools Protocol endpoint"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("Lets local tools drive Lua over the DevTools Protocol on 127.0.0.1. Any local process can control the browser while this is on — leave it off when you’re not using it. Takes effect after a relaunch.", comment: "Developer settings - Security note for the remote debugging toggle"))
                            .font(.system(size: 11))
                            .themedForeground(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { remoteDebuggingEnabled },
                        set: { newValue in
                            remoteDebuggingEnabled = newValue
                            // 0 = ephemeral port written to DevToolsActivePort.
                            PhiPreferences.AgentSpaces.remoteDebuggingPort = newValue ? 0 : nil
                            // Flush now so the relaunched process reads the new
                            // value (the whole point of an in-app toggle over a
                            // cross-process `defaults write`).
                            UserDefaults.standard.synchronize()
                            promptRelaunch(enabling: newValue)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func promptRelaunch(enabling: Bool) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Relaunch to apply?", comment: "Developer settings - Relaunch prompt title after toggling remote debugging")
        alert.informativeText = enabling
            ? NSLocalizedString("Remote debugging starts after Lua restarts.", comment: "Developer settings - Relaunch prompt body when enabling remote debugging")
            : NSLocalizedString("Remote debugging stops after Lua restarts.", comment: "Developer settings - Relaunch prompt body when disabling remote debugging")
        alert.addButton(withTitle: NSLocalizedString("Relaunch Now", comment: "Developer settings - Relaunch prompt confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Developer settings - Relaunch prompt dismiss button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let quoted = "'" + Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "( sleep 0.5; /usr/bin/open -n \(quoted) ) &"]
        try? relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// MARK: - lua-browser skill installer

private struct SkillInstallSectionView: View {
    // A Claude-Code-style coding agent that loads skills from a folder.
    // "Install" links this app's bundled lua-browser skill into
    // <skillsDirectory>/lua-browser so the agent can drive Lua over CDP.
    private struct SkillTarget: Identifiable {
        let id: String
        let name: String
        let skillsDirectory: URL

        var linkURL: URL {
            skillsDirectory.appendingPathComponent("lua-browser", isDirectory: true)
        }
    }

    private static let skillTargets: [SkillTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SkillTarget(id: "claude", name: "Claude Code",
                        skillsDirectory: home.appendingPathComponent(".claude/skills", isDirectory: true)),
            SkillTarget(id: "codex", name: "Codex",
                        skillsDirectory: home.appendingPathComponent(".codex/skills", isDirectory: true)),
            SkillTarget(id: "openclaw", name: "OpenClaw",
                        skillsDirectory: home.appendingPathComponent(".openclaw/skills", isDirectory: true)),
        ]
    }()

    // The skill tree is bundled at Contents/Resources/claude-skill/lua-browser.
    private static var bundledSkillURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("claude-skill/lua-browser", isDirectory: true)
    }

    // IDs of agents whose skills folder already links to *this* app's bundle.
    @State private var installedTargets: Set<String> = SkillInstallSectionView.installedTargetIDs()

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Agent skill", comment: "Developer settings - lua-browser skill section title")) {
            SettingsDetailCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Install the lua-browser skill", comment: "Developer settings - Title for installing the lua-browser agent skill"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("Links the skill bundled in this app into an AI coding agent’s skills folder so it can drive Lua over the DevTools Protocol. Requires Node 22+; enable remote debugging above so it can connect.", comment: "Developer settings - Explanation for the lua-browser skill installer"))
                            .font(.system(size: 11))
                            .themedForeground(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Menu {
                        Button(NSLocalizedString("All agents", comment: "Developer settings - Menu item installing the skill for every agent")) {
                            installAll()
                        }
                        Divider()
                        ForEach(Self.skillTargets) { target in
                            Button {
                                installSkill(for: target)
                            } label: {
                                // The checkmark marks agents whose skills folder
                                // already links to THIS app's bundle; picking one
                                // again reinstalls (refreshes the link).
                                if installedTargets.contains(target.id) {
                                    Label("\(target.name)  \(Self.displayPath(target.skillsDirectory))",
                                          systemImage: "checkmark")
                                } else {
                                    Text("\(target.name)  \(Self.displayPath(target.skillsDirectory))")
                                }
                            }
                        }
                    } label: {
                        Text(NSLocalizedString("Add skill to…", comment: "Developer settings - Dropdown button installing the lua-browser skill for an agent"))
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Installs for every known agent, reporting one aggregate alert instead
    /// of one per target.
    private func installAll() {
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        for target in Self.skillTargets {
            switch performInstall(for: target) {
            case .success: succeeded.append(target.name)
            case .cancelled: continue
            case .failure(let message): failed.append((target.name, message))
            }
        }
        if failed.isEmpty, succeeded.isEmpty { return }
        if failed.isEmpty {
            presentSkillAlert(
                title: NSLocalizedString("Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("%@ can now use the lua-browser skill. If it isn’t already on, enable remote debugging above and relaunch so the skill can connect.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    succeeded.joined(separator: ", ")),
                style: .informational)
        } else {
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                style: .warning)
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    static func installedTargetIDs() -> Set<String> {
        guard let bundled = bundledSkillURL else { return [] }
        return Set(skillTargets.filter { isLinked($0.linkURL, to: bundled) }.map(\.id))
    }

    // True only when linkURL is a symlink resolving to *this* app's bundled
    // skill, so a link left by another build (or a stale target) reads as
    // "Install" rather than already-installed.
    private static func isLinked(_ link: URL, to bundled: URL) -> Bool {
        guard let dest = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = dest.hasPrefix("/")
            ? dest
            : link.deletingLastPathComponent().appendingPathComponent(dest).path
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
            == bundled.standardizedFileURL.path
    }

    private enum InstallOutcome {
        case success
        case cancelled          // the user declined the overwrite prompt
        case failure(String)
    }

    /// Links the bundled skill into `target`'s skills folder. Silent apart
    /// from the overwrite confirmation (a non-symlink already in place must
    /// never be clobbered without asking) — callers present the outcome, so
    /// "All agents" can aggregate into one alert.
    private func performInstall(for target: SkillTarget) -> InstallOutcome {
        let fm = FileManager.default
        guard let bundled = Self.bundledSkillURL,
              fm.fileExists(atPath: bundled.path) else {
            return .failure(NSLocalizedString("This build doesn’t include the lua-browser skill resources. Rebuild Lua and try again.", comment: "Developer settings - Skill install failure body when the resource is missing"))
        }

        let link = target.linkURL
        do {
            try fm.createDirectory(at: target.skillsDirectory, withIntermediateDirectories: true)

            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                // An existing symlink (ours, another build's, or broken) — replace it.
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                // A real file/directory the user placed — don't clobber without asking.
                guard confirmSkillOverwrite(at: link.path) else { return .cancelled }
                try fm.removeItem(at: link)
            }

            try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
            installedTargets.insert(target.id)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func installSkill(for target: SkillTarget) {
        switch performInstall(for: target) {
        case .success:
            presentSkillAlert(
                title: NSLocalizedString("Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("%@ can now use the lua-browser skill. If it isn’t already on, enable remote debugging above and relaunch so the skill can connect.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    target.name),
                style: .informational)
        case .cancelled:
            break
        case .failure(let message):
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: message,
                style: .warning)
        }
    }

    private func confirmSkillOverwrite(at path: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Replace the existing skill?", comment: "Developer settings - Skill overwrite prompt title")
        alert.informativeText = String(
            format: NSLocalizedString("“%@” already exists and isn’t a link created by Lua. Replace it with a link to this app’s bundled skill?", comment: "Developer settings - Skill overwrite prompt body"),
            path)
        alert.addButton(withTitle: NSLocalizedString("Replace", comment: "Developer settings - Skill overwrite confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Developer settings - Skill overwrite cancel button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentSkillAlert(title: String, body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Developer settings - Alert dismiss button"))
        alert.runModal()
    }
}
