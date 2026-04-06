# Refactor SecretAgent certificate matching to support many certificates per key

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds. This plan follows `/Users/rw/.codex/PLANS.md`.

## Purpose / Big Picture

After this change, one Secretive key can advertise any number of OpenSSH certificates, regardless of how those certificate files are named on disk. The agent will match certificates to keys by reading each certificate, extracting the embedded subject public key, computing that key's fingerprint, and comparing it to the fingerprint of each managed key. A working result is visible when `requestIdentities` returns one bare key plus every matching certificate for that key, and when a sign request that uses a certificate blob still resolves to the underlying key.

## Progress

- [x] 2026-03-16 20:38Z Read the current key/certificate flow in `Agent`, `OpenSSHCertificateHandler`, `PublicKeyStandinFileController`, and `SSHAgentInputParser`.
- [x] 2026-03-16 20:38Z Confirmed current test coverage and current behavior with `xcodebuild test -project Sources/Secretive.xcodeproj -scheme PackageTests -destination 'platform=macOS' -only-testing:SecretAgentKitTests`.
- [x] 2026-03-16 21:14Z Introduced shared certificate parsing and key-blob fingerprint helpers in `Sources/Packages/Sources/SSHProtocolKit`.
- [x] 2026-03-16 21:29Z Refactored certificate discovery to scan certificate contents and build a one-to-many fingerprint index.
- [x] 2026-03-16 21:38Z Stopped treating certificate files as generated files that may be deleted during `clear: true`.
- [x] 2026-03-16 22:06Z Extended unit and integration tests for multi-certificate enumeration, fingerprint matching, cache clearing, and certificate-backed signing.

## Surprises & Discoveries

- Observation: the current cache stores only one `(Data, Data)` tuple per secret, so the model is structurally one-key-to-one-certificate.
  Evidence: `OpenSSHCertificateHandler.swift` stores `[AnySecret: (Data, Data)]`.
- Observation: `reloadCertificates(for:)` returns early when no `-cert.pub` files exist and does not clear cached entries.
  Evidence: `OpenSSHCertificateHandler.swift` short-circuits before resetting `keyBlobsAndNames`.
- Observation: `generatePublicKeys(clear: true)` currently deletes any file in `PublicKeys` that is not in a generated allowlist, which would remove extra certificate files on launch or reload.
  Evidence: `PublicKeyStandinFileController.swift` computes `untracked` from the full directory contents and removes those paths.
- Observation: request parsing already strips ECDSA certificate wrappers before matching a key, which means the best shared abstraction is "extract the subject key blob from a certificate blob".
  Evidence: `SSHAgentInputParser.certificatePublicKeyBlob(from:)`.
- Observation: the shared `PackageTests` plan did not include `SSHProtocolKitTests`, so the new protocol-level coverage would not run in the normal `xcodebuild test -scheme PackageTests` path until the plan was updated.
  Evidence: `Sources/Config/Secretive.xctestplan` originally listed only `BriefTests`, `SecretKitTests`, and `SecretAgentKitTests`.

## Decision Log

- Decision: use the fingerprint of the embedded subject public key as the certificate-to-secret match key.
  Rationale: filenames are arbitrary and one key may have many certificates, so filename-derived matching is incorrect.
  Date/Author: 2026-03-16 / Codex
- Decision: cache certificates by subject fingerprint string, not by `AnySecret`.
  Rationale: fingerprint keys naturally support one-to-many matching and remain stable across store reloads.
  Date/Author: 2026-03-16 / Codex
- Decision: move certificate parsing into `SSHProtocolKit` as shared protocol logic.
  Rationale: both disk loading and sign-request normalization need the same certificate parsing behavior.
  Date/Author: 2026-03-16 / Codex
- Decision: generated bare `.pub` stand-ins remain Secretive-managed; certificate files are treated as user-managed inputs and are never deleted by `clear: true`.
  Rationale: supporting many certificates per key is impossible if the agent deletes files it did not generate.
  Date/Author: 2026-03-16 / Codex
- Decision: keep `OpenSSHKeyFingerprint` as a dedicated namespace utility and avoid public blob-based fingerprint APIs.
  Rationale: the fingerprint logic is shared by the writer and certificate parser, but callers should continue using the established `secret:` methods rather than a broader public surface.
  Date/Author: 2026-03-16 / Codex
- Decision: remove `StoredCertificate` and keep the public certificate identity payload minimal.
  Rationale: once the cache stores parsed certificates directly, the extra wrapper and extra public metadata no longer provide value and just widen the structure.
  Date/Author: 2026-03-16 / Codex

## Outcomes & Retrospective

The refactor landed as planned. Certificate parsing now lives in `SSHProtocolKit`, certificate matching is content-driven by subject-key fingerprint, one key can advertise multiple certificates, certificate sign requests normalize to the underlying key blob, and `generatePublicKeys(clear: true)` no longer deletes user-managed certificate files. The new tests run against temp directories and fixture data, so the behavior is covered without touching the real `~/Library/.../PublicKeys` directory.

## Context and Orientation

A "key blob" in this repo is the SSH wire-format public key produced by `OpenSSHPublicKeyWriter.data(secret:)`. A "certificate blob" is the SSH wire-format certificate stored in an OpenSSH `*-cert.pub` line. Today the launch path begins in `Sources/SecretAgent/AppDelegate.swift`, which creates `Agent` and `PublicKeyFileStoreController`. `Sources/Packages/Sources/SecretAgentKit/Agent.swift` enumerates identities and signs requests. `Sources/Packages/Sources/SecretAgentKit/OpenSSHCertificateHandler.swift` currently assumes one certificate per secret by deriving exactly one certificate path from the secret fingerprint. `Sources/Packages/Sources/SecretAgentKit/PublicKeyStandinFileController.swift` manages on-disk `.pub` files. `Sources/Packages/Sources/SecretAgentKit/SSHAgentInputParser.swift` currently contains ECDSA-only logic to strip the certificate wrapper from a sign request. `Sources/Packages/Sources/SSHProtocolKit/OpenSSHPublicKeyWriter.swift` already knows how to serialize public key blobs and compute fingerprints for `Secret` values.

## Plan of Work

Milestone 1 introduces shared protocol helpers. Add a new parser in `Sources/Packages/Sources/SSHProtocolKit` that can read an OpenSSH authorized-keys line or raw certificate blob, identify whether it is a certificate, extract the embedded subject public key blob, and preserve the full trailing comment. At the same time, add fingerprint overloads that accept a raw key blob `Data` instead of requiring a `Secret`. This allows both the certificate loader and the request parser to compute the same canonical fingerprint from the same normalized public key representation.

Milestone 2 replaces the one-to-one certificate cache with a one-to-many fingerprint index. `OpenSSHCertificateHandler` should stop asking for "the certificate path for this secret". Instead it should enumerate candidate `.pub` files in the public key directory, parse only the ones that are certificates, compute each certificate's subject key fingerprint, and store an ordered array of certificate identities under that fingerprint. `Agent.identities()` then asks for all certificate identities for a secret and appends them after the bare key. `reloadCertificates` should always rebuild the cache from scratch so deletion is observed immediately.

Milestone 3 makes file ownership explicit and adds tests. `PublicKeyFileStoreController.generatePublicKeys(clear:)` should only prune generated bare public key stand-ins, never certificate files. Add temp-directory-based tests for handler loading and cleanup, and integration tests for agent enumeration and certificate-backed signing. The tests should use checked-in certificate fixtures or constants, not shell out to `ssh-keygen`, so the suite remains hermetic.

## Concrete Steps

Run all work from `/Users/rw/code/secretive`.

1. Add shared protocol helpers and tests.

   xcodebuild test -project Sources/Secretive.xcodeproj -scheme PackageTests -destination 'platform=macOS' -only-testing:SSHProtocolKitTests

2. Add handler, agent, and file-controller refactors plus SecretAgentKit tests.

   xcodebuild test -project Sources/Secretive.xcodeproj -scheme PackageTests -destination 'platform=macOS' -only-testing:SecretAgentKitTests

3. Run the combined package validation.

   xcodebuild test -project Sources/Secretive.xcodeproj -scheme PackageTests -destination 'platform=macOS'

A successful final run should include passing tests for the new multi-certificate cases and no failures in the existing agent tests.

## Validation and Acceptance

Acceptance is behavioral.

The new certificate loader is correct when a temp `PublicKeys` directory contains one generated bare key stand-in plus two certificate files with unrelated filenames whose embedded subject key is the same secret, and `Agent.identities()` returns three identities in stable order: the bare key followed by both certificates.

The new matching logic is correct when those same two certificates are renamed to different arbitrary filenames and the result is unchanged, proving the match comes from the embedded key fingerprint rather than from the filename.

The cache invalidation is correct when the temp directory is reloaded after deleting both certificate files and the agent returns only the bare key.

The sign path is correct when a `signRequest` uses a certificate blob as its requested key and `Agent.handle` returns `SSH_AGENT_SIGN_RESPONSE` because the parser normalized the certificate to the underlying subject key blob.

The cleanup logic is correct when `generatePublicKeys(clear: true)` removes stale generated bare `.pub` files but leaves user certificate files untouched.

## Idempotence and Recovery

All changes are additive until the old single-certificate path is removed. The directory-scan cache rebuild is naturally idempotent because each reload starts from an empty in-memory map. Tests must use temporary directories and injected handlers so reruns do not depend on or mutate the real user `PublicKeys` directory. If a refactor partially lands, the safe recovery path is to keep the old `keyBlobAndName` call sites compiling behind an adapter until the new `[OpenSSHCertificateIdentity]` interface is wired through.

## Artifacts and Notes

Observed test evidence after implementation:

   ✔ `OpenSSHCertificateReaderTests` passed
   ✔ `OpenSSHPublicKeyWriterTests` passed
   ✔ `OpenSSHCertificateHandlerTests` passed
   ✔ `PublicKeyFileStoreControllerTests` passed
   ✔ `AgentTests` passed, including the multi-certificate enumeration and certificate-backed signing cases
   ✔ `xcodebuild test -project Sources/Secretive.xcodeproj -scheme PackageTests -destination 'platform=macOS'` passed

## Interfaces and Dependencies

The final interfaces should look like this, or very close to it.

In `Sources/Packages/Sources/SSHProtocolKit/OpenSSHPublicKeyWriter.swift` keep the existing public fingerprint methods and add an internal helper namespace:

   public func openSSHSHA256Fingerprint<SecretType: Secret>(secret: SecretType) -> String
   public func openSSHMD5Fingerprint<SecretType: Secret>(secret: SecretType) -> String

   enum OpenSSHKeyFingerprint {
       static func sha256(for keyBlob: Data) -> String
       static func md5(for keyBlob: Data) -> String
   }

In a new `Sources/Packages/Sources/SSHProtocolKit/OpenSSHCertificateReader.swift` add a shared parser:

   public struct OpenSSHCertificateReader: Sendable {
       public init()
       public func readPublicKeyLine(_ line: String) throws -> ParsedCertificate
       public func readCertificateBlob(_ blob: Data) throws -> ParsedCertificate
   }

   public struct ParsedCertificate: Sendable, Hashable {
       public let certificateBlob: Data
       public let subjectKeyBlob: Data
       public let subjectKeyFingerprint: String
       public let comment: String?
       public let type: String
   }

In `Sources/Packages/Sources/SecretAgentKit/OpenSSHCertificateHandler.swift` replace the one-to-one lookup:

   public struct OpenSSHCertificateIdentity: Sendable, Hashable {
       public let keyBlob: Data
       public let comment: Data
   }

   public actor OpenSSHCertificateHandler {
       public init(directory: URL = URL.publicKeyDirectory, certificateReader: OpenSSHCertificateReader = .init(), publicKeyWriter: OpenSSHPublicKeyWriter = .init())
       public func reloadCertificates()
       public func certificateIdentities<SecretType: Secret>(for secret: SecretType) -> [OpenSSHCertificateIdentity]
   }

Delete `sshCertificatePath(for:)` from `PublicKeyFileStoreController`; it cannot model many certificates per key. Replace it with directory enumeration for certificate discovery and a managed-generated-files filter for cleanup.

In `Sources/Packages/Sources/SecretAgentKit/Agent.swift` update the init and enumeration call sites:

   public init(storeList: SecretStoreList, witness: SigningWitness? = nil, certificateHandler: OpenSSHCertificateHandler = OpenSSHCertificateHandler())

`identities()` should append every value returned by `certificateIdentities(for:)`, not a single optional tuple.

In `Sources/Packages/Sources/SecretAgentKit/SSHAgentInputParser.swift`, replace `certificatePublicKeyBlob(from:) -> Data?` with a helper that uses `OpenSSHCertificateReader` and returns the normalized subject key blob for any supported certificate type. The sign path should continue matching on the normalized key blob, not on certificate comments or filenames.

Prospective tests to add:

- `SSHProtocolKitTests/OpenSSHCertificateReaderTests.swift`
- `SecretAgentKitTests/OpenSSHCertificateHandlerTests.swift`
- Extensions to `SecretAgentKitTests/AgentTests.swift`
- Extensions to `SecretAgentKitTests` or a new `PublicKeyFileStoreControllerTests.swift`

Plan revision note: initial draft created after reviewing current agent/certificate code and existing tests, with scope expanded to include cleanup behavior because the current `clear: true` path would delete extra certificate files and would otherwise block the requested many-certificates-per-key behavior. Updated after implementation to record the shared certificate parser, the test-plan change needed to run `SSHProtocolKitTests`, and the final passing validation run.
