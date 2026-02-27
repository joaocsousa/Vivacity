import Foundation
import os

protocol SessionManaging: Sendable {
    func save(_ session: ScanSession) async throws
    func loadAll() async throws -> [ScanSession]
    func loadSession(id: UUID) async throws -> ScanSession?
    func deleteSession(id: UUID) async throws
}

final class SessionManager: SessionManaging {
    private let logger = Logger(subsystem: "com.vivacity.app", category: "SessionManager")
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private var sessionsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vivacityURL = appSupport.appendingPathComponent("Vivacity")
        return vivacityURL.appendingPathComponent("Sessions")
    }

    private func ensureDirectoryExists() throws {
        let dir = sessionsDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func save(_ session: ScanSession) async throws {
        try ensureDirectoryExists()
        let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Use a background task to encode since files can be large
        let data = try await Task.detached(priority: .userInitiated) {
            try encoder.encode(session)
        }.value

        try data.write(to: fileURL, options: .atomic)
        logger.info("Saved session \(session.id) to \(fileURL.path)")
    }

    func loadAll() async throws -> [ScanSession] {
        try ensureDirectoryExists()
        let dir = sessionsDirectory

        let urls = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var sessions: [ScanSession] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Decode them concurrently
        try await withThrowingTaskGroup(of: ScanSession?.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let data = try Data(contentsOf: url)
                        return try decoder.decode(ScanSession.self, from: data)
                    } catch {
                        // Just log corrupt/old formats and skip
                        self.logger.error("Failed to decode session at \(url.path): \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            for try await session in group {
                if let session {
                    sessions.append(session)
                }
            }
        }

        return sessions.sorted { $0.dateSaved > $1.dateSaved }
    }

    func loadSession(id: UUID) async throws -> ScanSession? {
        let fileURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try await Task.detached(priority: .userInitiated) {
            try decoder.decode(ScanSession.self, from: data)
        }.value
    }

    func deleteSession(id: UUID) async throws {
        let fileURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
            logger.info("Deleted session \(fileURL.path)")
        }
    }
}
