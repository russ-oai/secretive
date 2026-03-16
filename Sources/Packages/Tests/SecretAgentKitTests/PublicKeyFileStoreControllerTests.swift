import Foundation
import Testing
import SecretKit
@testable import SecretAgentKit
import Common

@Suite struct PublicKeyFileStoreControllerTests {

    @Test func clearGeneratedPublicKeysLeavesCertificateFilesAlone() throws {
        let directory = try CertificateTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = PublicKeyFileStoreController(directory: directory)
        let managedStaleURL = directory.appending(path: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pub")
        let certificateURL = directory.appending(path: "team-alpha-access.pub")

        try Data("stale".utf8).write(to: managedStaleURL, options: .atomic)
        try CertificateTestFixtures.write(
            CertificateTestFixtures.certificateLine(for: CertificateTestFixtures.ecdsa256Secret, comment: "Team alpha cert"),
            to: certificateURL
        )

        try controller.generatePublicKeys(for: [AnySecret(CertificateTestFixtures.ecdsa256Secret)], clear: true)

        #expect(FileManager.default.fileExists(atPath: URL.publicKeyPath(for: CertificateTestFixtures.ecdsa256Secret, in: directory)))
        #expect(!FileManager.default.fileExists(atPath: managedStaleURL.path()))
        #expect(FileManager.default.fileExists(atPath: certificateURL.path()))
    }

}
