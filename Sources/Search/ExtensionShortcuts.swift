import AppKit
import SwiftUI
import WebKit

@available(macOS 15.4, *)
@MainActor
final class ExtensionShortcuts: ObservableObject {
    private struct Value: Codable { var key: KeyCombo? }
    @Published private var overrides: [String: [String: Value]]
    private var defaults: [String: [String: Value]] = [:]

    init() {
        overrides = Store.settings.data(forKey: "extensions.shortcuts")
            .flatMap { try? JSONDecoder().decode([String: [String: Value]].self, from: $0) } ?? [:]
    }

    static func key(_ command: WKWebExtension.Command) -> KeyCombo? {
        guard let key = command.activationKey, !key.isEmpty else { return nil }
        let flags = command.modifierFlags
        return KeyCombo(key == " " ? "space" : key, command: flags.contains(.command),
                        shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
    }

    func loaded(_ context: WKWebExtensionContext, id: String) {
        defaults[id] = Dictionary(uniqueKeysWithValues: context.commands.map { ($0.id, Value(key: Self.key($0))) })
        for command in context.commands {
            let key = overrides[id]?[command.id]?.key ?? Self.key(command)
            if let value = overrides[id]?[command.id] {
                apply(value.key, to: command)
            }
            if let key, conflict(key, id: id, command: command.id) != nil { apply(nil, to: command) }
        }
        objectWillChange.send()
    }

    func changed(_ id: String, command: String) -> Bool { overrides[id]?[command] != nil }

    static func owner(of key: KeyCombo, except id: String = "", command: String = "") -> String? {
        for (extensionID, context) in Extensions.shared.contexts {
            for candidate in context.commands where extensionID != id || candidate.id != command {
                if Self.key(candidate) == key {
                    let name = Extensions.shared.installed.first { $0.id == extensionID }?.name ?? extensionID
                    return "\(name): \(candidate.title)"
                }
            }
        }
        return nil
    }

    private func conflict(_ key: KeyCombo, id: String, command: String) -> String? {
        if KeyCombo.isReserved(key) { return "Reserved by macOS or SearchX" }
        if let browser = Extensions.shared.browser,
           let owner = browser.shortcuts.owner(of: key, except: "") { return "Used by \(owner.title)" }
        if let owner = Self.owner(of: key, except: id, command: command) { return "Used by \(owner)" }
        return nil
    }

    func assign(_ key: KeyCombo, id: String, command: WKWebExtension.Command) -> String? {
        guard key.key.count == 1 || key.key == "space" else { return "Use a letter, number, punctuation or Space" }
        if let conflict = conflict(key, id: id, command: command.id) { return conflict }
        overrides[id, default: [:]][command.id] = Value(key: key)
        apply(key, to: command)
        save()
        return nil
    }

    func clear(_ id: String, command: WKWebExtension.Command) {
        overrides[id, default: [:]][command.id] = Value(key: nil)
        apply(nil, to: command)
        save()
    }

    func reset(_ id: String, command: WKWebExtension.Command) -> String? {
        let key = defaults[id]?[command.id]?.key
        if let key, let conflict = conflict(key, id: id, command: command.id) { return conflict }
        overrides[id]?[command.id] = nil
        if overrides[id]?.isEmpty == true { overrides[id] = nil }
        apply(key, to: command)
        save()
        return nil
    }

    private func apply(_ key: KeyCombo?, to command: WKWebExtension.Command) {
        command.activationKey = key.map { $0.key == "space" ? " " : $0.key }
        var flags: NSEvent.ModifierFlags = []
        if key?.command == true { flags.insert(.command) }
        if key?.option == true { flags.insert(.option) }
        if key?.shift == true { flags.insert(.shift) }
        if key?.control == true { flags.insert(.control) }
        command.modifierFlags = flags
    }

    private func save() {
        Store.settings.set(try? JSONEncoder().encode(overrides), forKey: "extensions.shortcuts")
    }
}

@available(macOS 15.4, *)
struct ExtensionCommandKeys: View {
    let id: String
    let context: WKWebExtensionContext
    @ObservedObject var store: ExtensionShortcuts
    @ObservedObject var shortcuts: ShortcutStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(context.commands, id: \.id) { command in
                HStack {
                    Text(command.title.isEmpty ? command.id : command.title)
                        .font(.system(size: 12))
                    Spacer()
                    ShortcutRecorder(title: command.title, key: ExtensionShortcuts.key(command),
                                     changed: store.changed(id, command: command.id), store: shortcuts,
                                     accept: { store.assign($0, id: id, command: command) },
                                     clear: { store.clear(id, command: command) })
                    Button("Clear") { store.clear(id, command: command) }
                        .accessibilityLabel("Clear shortcut for \(command.title)")
                    Button("Reset") { error = store.reset(id, command: command) }
                        .accessibilityLabel("Reset shortcut for \(command.title)")
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}
