import Foundation
import OSLog
import SecretKit
import SSHProtocolKit
import Common

/// Controller responsible for writing public keys to disk, so that they're easily accessible by scripts.
public final class PublicKeyFileStoreController: Sendable {

    private let logger = Logger(subsystem: "com.maxgoedjen.secretive.secretagent", category: "PublicKeyFileStoreController")
    private let directory: URL
    private let keyWriter = OpenSSHPublicKeyWriter()

    /// Initializes a PublicKeyFileStoreController.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes out the keys specified to disk.
    /// - Parameter secrets: The Secrets to generate keys for.
    /// - Parameter clear: Whether or not any untracked files in the directory should be removed.
    public func generatePublicKeys(for secrets: [AnySecret], clear: Bool = false) throws {
        logger.log("Writing public keys to disk")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        if clear {
            let validPaths = Set(secrets.map { URL.publicKeyPath(for: $0, in: directory) })
            let contentsOfDirectory = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
            let managedPathContents = contentsOfDirectory
                .filter(isGeneratedPublicKeyFilename(_:))
                .map { directory.appending(path: $0).path() }

            let untracked = Set(managedPathContents)
                .subtracting(validPaths)
            for path in untracked {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
        for secret in secrets {
            let path = URL.publicKeyPath(for: secret, in: directory)
            let data = Data(keyWriter.openSSHString(secret: secret).utf8)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        logger.log("Finished writing public keys")
    }

}

extension PublicKeyFileStoreController {

    private func isGeneratedPublicKeyFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".pub") else {
            return false
        }
        let basename = filename.dropLast(4)
        return basename.count == 32 && basename.allSatisfy(\.isHexDigit)
    }

}
