import Foundation

/// Represents a saved scan session that can be resumed.
struct ScanSession: Codable, Identifiable, Equatable, Sendable, Hashable {
    let id: UUID
    let dateSaved: Date
    let deviceID: String
    let deviceTotalCapacity: Int64
    let lastScannedOffset: Int64
    let discoveredFiles: [RecoverableFile]
    
    init(id: UUID = UUID(),
         dateSaved: Date = Date(),
         deviceID: String,
         deviceTotalCapacity: Int64,
         lastScannedOffset: Int64,
         discoveredFiles: [RecoverableFile]) {
        self.id = id
        self.dateSaved = dateSaved
        self.deviceID = deviceID
        self.deviceTotalCapacity = deviceTotalCapacity
        self.lastScannedOffset = lastScannedOffset
        self.discoveredFiles = discoveredFiles
    }
}
