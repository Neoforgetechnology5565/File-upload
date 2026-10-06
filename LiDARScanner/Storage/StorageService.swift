import Foundation

enum StorageError: Error, LocalizedError, Equatable {
    case insufficientSpace(required: Int64, available: Int64)
    case directoryUnavailable(String)
    case fileMissing(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            let formatter = ByteCountFormatter()
            return "Needs \(formatter.string(fromByteCount: required)), but only \(formatter.string(fromByteCount: available)) is available."
        case .directoryUnavailable(let path): return "The storage folder is unavailable (\(path))."
        case .fileMissing(let name): return "The file \(name) is missing."
        case .writeFailed(let reason): return "Writing failed: \(reason)"
        }
    }
}

/// File storage for scan payloads (geometry, thumbnails, RoomPlan files,
/// exports). Metadata lives in `ScanRepository`; this protocol owns bytes.
///
/// A cloud implementation would typically wrap the local one (local cache +
/// upload), keeping this interface unchanged for the rest of the app.
protocol StorageService: Sendable {
    /// A fresh directory for an in-progress (unsaved) scan.
    func makeStagingDirectory() throws -> URL
    func discardStaging(_ url: URL)
    /// Atomically moves a staging directory to the permanent scan location.
    func commitStaging(_ staging: URL, scanID: UUID) throws
    func scanDirectory(for scanID: UUID) -> URL
    func fileURL(_ relativePath: String, scanID: UUID) -> URL
    func exportsDirectory(for scanID: UUID) throws -> URL
    func deleteFiles(for scanID: UUID) throws
    func write(_ data: Data, to url: URL) throws
    func availableCapacity() -> Int64?
    func ensureCapacity(_ bytes: Int64) throws
    func totalSize(for scanID: UUID) -> Int64
    func totalUsage() -> Int64
    func removeAllExports() throws
    func purgeStaleStagingDirectories()
}

/// Default on-device implementation:
/// ```
/// Application Support/
///   Scans/<scan-id>/geometry.lsgeo, thumbnail.jpg, room.usdz, captured-room.json, exports/
///   Staging/<uuid>/   (unsaved scans; purged on launch)
/// ```
/// Files are written with `completeUntilFirstUserAuthentication` protection.
final class LocalFileStorageService: StorageService, @unchecked Sendable {
    private let fileManager: FileManager
    let rootURL: URL

    private var scansURL: URL { rootURL.appendingPathComponent("Scans", isDirectory: true) }
    private var stagingURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.rootURL = support.appendingPathComponent("LiDARScanner", isDirectory: true)
        }
        try createDirectory(scansURL)
        try createDirectory(stagingURL)
    }

    func makeStagingDirectory() throws -> URL {
        let url = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(url)
        return url
    }

    func discardStaging(_ url: URL) {
        guard url.path.hasPrefix(stagingURL.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func commitStaging(_ staging: URL, scanID: UUID) throws {
        let destination = scanDirectory(for: scanID)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
    }

    func scanDirectory(for scanID: UUID) -> URL {
        scansURL.appendingPathComponent(scanID.uuidString, isDirectory: true)
    }

    func fileURL(_ relativePath: String, scanID: UUID) -> URL {
        scanDirectory(for: scanID).appendingPathComponent(relativePath)
    }

    func exportsDirectory(for scanID: UUID) throws -> URL {
        let url = scanDirectory(for: scanID).appendingPathComponent("exports", isDirectory: true)
        try createDirectory(url)
        return url
    }

    func deleteFiles(for scanID: UUID) throws {
        let url = scanDirectory(for: scanID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try ensureCapacity(Int64(data.count))
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw StorageError.insufficientSpace(required: Int64(data.count), available: availableCapacity() ?? 0)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
    }

    func availableCapacity() -> Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Keeps a 100 MB safety margin so the system stays healthy.
    func ensureCapacity(_ bytes: Int64) throws {
        guard let available = availableCapacity() else { return }
        let margin: Int64 = 100 * 1024 * 1024
        if bytes + margin > available {
            throw StorageError.insufficientSpace(required: bytes + margin, available: available)
        }
    }

    func totalSize(for scanID: UUID) -> Int64 {
        directorySize(scanDirectory(for: scanID))
    }

    func totalUsage() -> Int64 {
        directorySize(rootURL)
    }

    func removeAllExports() throws {
        let scanDirectories = (try? fileManager.contentsOfDirectory(at: scansURL, includingPropertiesForKeys: nil)) ?? []
        for directory in scanDirectories {
            let exports = directory.appendingPathComponent("exports", isDirectory: true)
            if fileManager.fileExists(atPath: exports.path) {
                try fileManager.removeItem(at: exports)
            }
        }
    }

    /// Staging folders belong to scans that were never saved (app killed
    /// during processing, user discarded). They are safe to delete at launch.
    func purgeStaleStagingDirectories() {
        let contents = (try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Helpers

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
        } catch {
            throw StorageError.directoryUnavailable(url.lastPathComponent)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
