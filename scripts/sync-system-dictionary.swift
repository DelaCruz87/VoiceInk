#!/usr/bin/env swift

import Foundation
import SwiftData

// Ad-hoc local utility for Eme's VoiceInk-GPL dictionary. It inventories the live Mac, Obsidian ENSO, and
// SiYuan SY-ENSO installations. If upstream changes the SwiftData models or store configuration, revalidate
// this schema against the app and run against a copied store before using it again.
@Model
final class VocabularyWord {
    var word: String = ""
    var dateAdded: Date = Date()

    init(word: String, dateAdded: Date = Date()) {
        self.word = word
        self.dateAdded = dateAdded
    }
}

@Model
final class WordReplacement {
    var id: UUID = UUID()
    var originalText: String = ""
    var replacementText: String = ""
    var dateAdded: Date = Date()
    var isEnabled: Bool = true

    init(originalText: String, replacementText: String, dateAdded: Date = Date(), isEnabled: Bool = true) {
        self.originalText = originalText
        self.replacementText = replacementText
        self.dateAdded = dateAdded
        self.isEnabled = isEnabled
    }
}

enum SyncError: Error, CustomStringConvertible {
    case usage
    case unreadableManifest(URL)

    var description: String {
        switch self {
        case .usage:
            return "Usage: sync-system-dictionary.swift <dictionary.store>"
        case .unreadableManifest(let url):
            return "Could not read manifest: \(url.path)"
        }
    }
}

func jsonObject(at url: URL) throws -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: url.path),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw SyncError.unreadableManifest(url)
    }
    return object
}

func add(_ candidate: Any?, to names: inout [String: String]) {
    guard let value = candidate as? String else { return }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    names[trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)] = trimmed
}

func manifestURLs(root: URL, name: String) -> [URL] {
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return children.map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
}

func applicationURLs(roots: [URL]) -> [URL] {
    var applications: [URL] = []
    for root in roots {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { continue }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            applications.append(url)
        }
    }
    return applications
}

do {
    guard CommandLine.arguments.count == 2 else { throw SyncError.usage }
    let storeURL = URL(fileURLWithPath: CommandLine.arguments[1])
    var names: [String: String] = [:]

    let obsidianRoot = URL(fileURLWithPath: "/Users/eme/Obsidian/ENSO/.obsidian/plugins", isDirectory: true)
    for url in manifestURLs(root: obsidianRoot, name: "manifest.json") {
        let manifest = try jsonObject(at: url)
        add(manifest["name"], to: &names)
        add(manifest["id"], to: &names)
    }

    let siyuanRoot = URL(fileURLWithPath: "/Users/eme/SiYuan/SY-ENSO/data/plugins", isDirectory: true)
    for url in manifestURLs(root: siyuanRoot, name: "plugin.json") {
        let manifest = try jsonObject(at: url)
        add(manifest["name"], to: &names)
        if let displayNames = manifest["displayName"] as? [String: Any] {
            add(displayNames["default"], to: &names)
            add(displayNames["en_US"], to: &names)
        }
    }

    let appRoots = ["/Applications", "/Users/eme/Applications", "/System/Applications"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    for appURL in applicationURLs(roots: appRoots) {
        add(appURL.deletingPathExtension().lastPathComponent, to: &names)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let data = FileManager.default.contents(atPath: plistURL.path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            add(plist["CFBundleDisplayName"], to: &names)
            add(plist["CFBundleName"], to: &names)
        }
    }

    let schema = Schema([VocabularyWord.self, WordReplacement.self])
    let configuration = ModelConfiguration("dictionary", schema: schema, url: storeURL, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: configuration)
    let context = ModelContext(container)
    let existing = try context.fetch(FetchDescriptor<VocabularyWord>())
    let existingKeys = Set(existing.map {
        $0.word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    })
    let additions = names.filter { !existingKeys.contains($0.key) }.map(\.value).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    for word in additions {
        context.insert(VocabularyWord(word: word))
    }
    if !additions.isEmpty {
        try context.save()
    }

    print("inventory=\(names.count) existing=\(existing.count) inserted=\(additions.count) final=\(existing.count + additions.count)")
} catch {
    fputs("sync-system-dictionary: \(error)\n", stderr)
    exit(1)
}
