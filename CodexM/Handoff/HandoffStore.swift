import Foundation

actor HandoffStore {
    let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("Handoffs", isDirectory: true) }
    private func safe(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw CodexMError.unsafePath }
    }
    func save(_ draft: HandoffDraft) throws -> HandoffPackage {
        guard draft.manifest.version == 1, draft.manifest.source.profileId != draft.manifest.target.profileId else { throw CodexMError.handoffSelection }
        try safe(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(draft.manifest.id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CodexMError.directoryNotEmpty }
        let stage = root.appendingPathComponent(".preparing-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let context = String(SecretRedactor.clean(draft.context).text.prefix(ContextBuilder.budget))
        let package = HandoffPackage(manifest: draft.manifest, directory: directory, context: context)
        try write(Data(context.utf8), to: stage.appendingPathComponent("context.md"))
        try write(try encoder().encode(draft.manifest), to: stage.appendingPathComponent("manifest.json"))
        try FileManager.default.moveItem(at: stage, to: directory)
        return package
    }
    func recent() throws -> [HandoffPackage] {
        try safe(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { try? read(directory: $0) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }.prefix(50).map { $0 }
    }
    func update(_ package: HandoffPackage, status: HandoffStatus) throws -> HandoffPackage {
        let directory = root.appendingPathComponent(package.id.uuidString, isDirectory: true)
        let current = try read(directory: directory)
        var manifest = current.manifest; manifest.status = status
        try write(try encoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"))
        return HandoffPackage(manifest: manifest, directory: directory, context: current.context)
    }
    private func read(directory: URL) throws -> HandoffPackage {
        try safe(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let contextURL = directory.appendingPathComponent("context.md")
        for url in [manifestURL, contextURL] {
            try safe(url)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 200_000 else { throw CodexMError.handoffPackage }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(HandoffManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.id.uuidString == directory.lastPathComponent else { throw CodexMError.handoffPackage }
        return HandoffPackage(manifest: manifest, directory: directory, context: SecretRedactor.clean(try String(contentsOf: contextURL, encoding: .utf8)).text)
    }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    private func write(_ data: Data, to url: URL) throws {
        try safe(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
