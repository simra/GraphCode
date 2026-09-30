import Foundation

public struct ProjectRelocationOptions: Codable, Equatable, Sendable {
  public var migrateSupportState: Bool

  public init(migrateSupportState: Bool = true) {
    self.migrateSupportState = migrateSupportState
  }
}
public struct ProjectRelocationRequest: Codable, Equatable, Sendable {
  public var operationID: UUID
  public var sourcePath: String
  public var destinationPath: String
  public var expectedSourceIdentity: String
  public var expectedGraphRevision: Int
  public var options: ProjectRelocationOptions

  public init(
    operationID: UUID,
    sourcePath: String,
    destinationPath: String,
    expectedSourceIdentity: String,
    expectedGraphRevision: Int,
    options: ProjectRelocationOptions = ProjectRelocationOptions()
  ) {
    self.operationID = operationID
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.expectedSourceIdentity = expectedSourceIdentity
    self.expectedGraphRevision = expectedGraphRevision
    self.options = options
  }
}
public struct ProjectRelocationPlan: Codable, Equatable, Sendable {
  public var operationID: UUID
  public var sourcePath: String
  public var destinationPath: String
  public var sourceIdentity: String
  public var graphRevision: Int

  public init(
    operationID: UUID,
    sourcePath: String,
    destinationPath: String,
    sourceIdentity: String,
    graphRevision: Int
  ) {
    self.operationID = operationID
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.sourceIdentity = sourceIdentity
    self.graphRevision = graphRevision
  }
}
public enum ProjectRelocationRecoveryDisposition: String, Codable, Equatable, Sendable {
  case recovered
  case abandonedBeforeCommit
  case quarantined
}
public struct ProjectRelocationRecoveryStatus: Codable, Equatable, Sendable {
  public var operationID: UUID?
  public var disposition: ProjectRelocationRecoveryDisposition
  public var detail: String

  public init(
    operationID: UUID?,
    disposition: ProjectRelocationRecoveryDisposition,
    detail: String
  ) {
    self.operationID = operationID
    self.disposition = disposition
    self.detail = detail
  }
}
public struct ProjectRelocationResult: Codable, Equatable, Sendable {
  public var operationID: UUID
  public var sourcePath: String
  public var destinationPath: String
  public var sourceIdentity: String
  public var graphRevision: Int
  public var recoveryRequired: Bool

  public init(
    operationID: UUID,
    sourcePath: String,
    destinationPath: String,
    sourceIdentity: String,
    graphRevision: Int,
    recoveryRequired: Bool = false
  ) {
    self.operationID = operationID
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.sourceIdentity = sourceIdentity
    self.graphRevision = graphRevision
    self.recoveryRequired = recoveryRequired
  }
}
public enum ProjectRelocationError: String, Error, Codable, Equatable, LocalizedError, Sendable {
  case unauthorized
  case unsupported
  case sourceMissing
  case sourceIdentityChanged
  case graphRevisionChanged
  case activeSessions
  case activeWorktrees
  case destinationCollision
  case unsafePath
  case crossVolume
  case permissionDenied
  case preflightFailed
  case rolledBack
  case rollbackFailed
  case recoveryFailed
  case duplicateConflict
  case transportFailure

  public var errorDescription: String? {
    switch self {
    case .unauthorized: return "project relocation was not authorized for this client"
    case .unsupported: return "project relocation is unsupported for this project"
    case .sourceMissing: return "the source project directory is missing"
    case .sourceIdentityChanged: return "the source project identity changed"
    case .graphRevisionChanged: return "the source graph revision changed"
    case .activeSessions: return "the project has active sessions"
    case .activeWorktrees: return "the project has worktrees, submodules, or worktree bindings"
    case .destinationCollision: return "the destination already exists or collides by case"
    case .unsafePath: return "the source or destination path is unsafe"
    case .crossVolume: return "cross-volume project relocation is unsupported"
    case .permissionDenied: return "project relocation lacks required filesystem permission"
    case .preflightFailed: return "project relocation preflight failed"
    case .rolledBack: return "project relocation failed after rename and was rolled back"
    case .rollbackFailed: return "project relocation rollback could not be completed"
    case .recoveryFailed: return "project relocation recovery could not determine one authority"
    case .duplicateConflict: return "the relocation operation id was reused with different input"
    case .transportFailure: return "project relocation transport failed"
    }
  }
}
public enum ProjectRelocationFaultPoint: String, Sendable {
  case beforeJournal
  case beforeFilesystemCommit
  case afterFilesystemCommit
  case beforeSupportCommit
  case afterSupportCommit
  case beforeRollback
}
public final class ProjectRelocationCoordinator: @unchecked Sendable {
  private struct Journal: Codable {
    enum Phase: String, Codable {
      case prepared
      case filesystemCommitted
    }

    var request: ProjectRelocationRequest
    var authorizedClientID: UUID
    var plan: ProjectRelocationPlan
    var graph: LoopGraph
    var phase: Phase
  }
  private struct Receipt: Codable {
    var request: ProjectRelocationRequest
    var authorizedClientID: UUID
    var result: ProjectRelocationResult
  }

  private let supportDirectory: URL
  private let platformPaths: any PlatformPaths
  private let fileManager: FileManager
  private let fault: @Sendable (ProjectRelocationFaultPoint) throws -> Void
  private static let processLock = NSLock()

  public init(
    supportDirectory: URL,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value,
    fileManager: FileManager = .default,
    fault: @escaping @Sendable (ProjectRelocationFaultPoint) throws -> Void = { _ in }
  ) {
    self.supportDirectory = supportDirectory
    self.platformPaths = platformPaths
    self.fileManager = fileManager
    self.fault = fault
  }

  public func prepare(
    operationID: UUID = UUID(),
    sourcePath: String,
    destinationPath: String,
    graphRevision: Int,
    options: ProjectRelocationOptions = ProjectRelocationOptions(),
    persistence: ProjectPersistence? = nil
  ) throws -> ProjectRelocationPlan {
    try withMutationLock {
      let persistence =
        persistence
        ?? ProjectPersistence(
          baseDirectory: supportDirectory,
          platformPaths: platformPaths)
      guard options.migrateSupportState else {
        throw ProjectRelocationError.unsupported
      }
      guard !fileManager.fileExists(atPath: receiptURL(operationID).path),
        !fileManager.fileExists(atPath: journalURL(operationID).path)
      else {
        throw ProjectRelocationError.duplicateConflict
      }
      return try preflight(
        operationID: operationID,
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        graphRevision: graphRevision,
        persistence: persistence)
    }
  }

  public func relocate(
    _ request: ProjectRelocationRequest,
    authorizedClientID: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
    graph: LoopGraph,
    persistence: ProjectPersistence
  ) throws -> ProjectRelocationResult {
    try withMutationLock {
      guard request.options.migrateSupportState else {
        throw ProjectRelocationError.unsupported
      }
      if let replay = try validatedReplay(
        for: request, authorizedClientID: authorizedClientID)
      {
        return replay
      }

      let stableSource = try StableProjectDirectory(path: request.sourcePath)
      let plan = try preflight(
        operationID: request.operationID,
        sourcePath: request.sourcePath,
        destinationPath: request.destinationPath,
        graphRevision: request.expectedGraphRevision,
        persistence: persistence)
      guard plan.sourceIdentity == request.expectedSourceIdentity else {
        throw ProjectRelocationError.sourceIdentityChanged
      }
      guard stableSource.identityToken == plan.sourceIdentity else {
        throw ProjectRelocationError.sourceIdentityChanged
      }
      let destinationProject = ProjectRef(
        path: plan.destinationPath,
        name: URL(fileURLWithPath: plan.destinationPath).lastPathComponent,
        lastOpenedAt: graph.project.lastOpenedAt,
        metadata: graph.project.metadata)
      let rewrittenGraph = graph.enforcingRootProject(destinationProject)
      let journal = Journal(
        request: request,
        authorizedClientID: authorizedClientID,
        plan: plan,
        graph: rewrittenGraph,
        phase: .prepared)

      try fault(.beforeJournal)
      try writeJournal(journal)
      do {
        try fault(.beforeFilesystemCommit)
        try stableSource.verify(path: plan.sourcePath)
        guard !containsWorktreeTopology(at: plan.sourcePath) else {
          throw ProjectRelocationError.activeWorktrees
        }
        try persistence.preflightProjectRelocationDestination(plan.destinationPath)
        try preflightRelocationState(
          destinationPath: plan.destinationPath,
          excluding: request.operationID)
        try StableProjectDirectory.inspectDestinationParent(
          URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent().path)
        try stableSource.rename(to: plan.destinationPath)
      } catch let relocationError as ProjectRelocationError {
        try? removeJournal(request.operationID)
        throw relocationError
      } catch {
        try? removeJournal(request.operationID)
        throw mapFilesystemError(error)
      }

      var committedJournal = journal
      committedJournal.phase = .filesystemCommitted
      var supportCommitStarted = false
      do {
        try writeJournal(committedJournal)
        try fault(.afterFilesystemCommit)
        try fault(.beforeSupportCommit)
        supportCommitStarted = true
        try persistence.completeProjectRelocation(
          from: plan.sourcePath, to: plan.destinationPath, graph: rewrittenGraph,
          supportSourcePath: graph.project.path)
        try fault(.afterSupportCommit)
      } catch {
        if supportCommitStarted {
          return ProjectRelocationResult(
            operationID: request.operationID,
            sourcePath: plan.sourcePath,
            destinationPath: plan.destinationPath,
            sourceIdentity: plan.sourceIdentity,
            graphRevision: request.expectedGraphRevision,
            recoveryRequired: true)
        }
        do {
          try fault(.beforeRollback)
          guard !fileManager.fileExists(atPath: plan.sourcePath),
            fileManager.fileExists(atPath: plan.destinationPath),
            try identityToken(at: plan.destinationPath) == plan.sourceIdentity
          else {
            return ProjectRelocationResult(
              operationID: request.operationID,
              sourcePath: plan.sourcePath,
              destinationPath: plan.destinationPath,
              sourceIdentity: plan.sourceIdentity,
              graphRevision: request.expectedGraphRevision,
              recoveryRequired: true)
          }
          try stableSource.verify(path: plan.destinationPath)
          try stableSource.rename(to: plan.sourcePath)
          try? removeJournal(request.operationID)
          throw ProjectRelocationError.rolledBack
        } catch ProjectRelocationError.rolledBack {
          throw ProjectRelocationError.rolledBack
        } catch {
          return ProjectRelocationResult(
            operationID: request.operationID,
            sourcePath: plan.sourcePath,
            destinationPath: plan.destinationPath,
            sourceIdentity: plan.sourceIdentity,
            graphRevision: request.expectedGraphRevision,
            recoveryRequired: true)
        }
      }

      let result = ProjectRelocationResult(
        operationID: request.operationID,
        sourcePath: plan.sourcePath,
        destinationPath: plan.destinationPath,
        sourceIdentity: plan.sourceIdentity,
        graphRevision: request.expectedGraphRevision)
      do {
        try writeReceipt(
          Receipt(
            request: request,
            authorizedClientID: authorizedClientID,
            result: result))
        try removeJournal(request.operationID)
        return result
      } catch {
        return ProjectRelocationResult(
          operationID: result.operationID,
          sourcePath: result.sourcePath,
          destinationPath: result.destinationPath,
          sourceIdentity: result.sourceIdentity,
          graphRevision: result.graphRevision,
          recoveryRequired: true)
      }
    }
  }

  public func replayResult(
    for request: ProjectRelocationRequest,
    authorizedClientID: UUID
  ) throws -> ProjectRelocationResult? {
    try withMutationLock {
      try validatedReplay(for: request, authorizedClientID: authorizedClientID)
    }
  }

  private func validatedReplay(
    for request: ProjectRelocationRequest,
    authorizedClientID: UUID
  ) throws -> ProjectRelocationResult? {
    guard let receipt = try loadReceipt(request.operationID) else { return nil }
    guard receipt.authorizedClientID == authorizedClientID else {
      throw ProjectRelocationError.unauthorized
    }
    guard receipt.request == request else {
      throw ProjectRelocationError.duplicateConflict
    }
    return receipt.result
  }

  public func recoverPending(
    persistence: ProjectPersistence
  ) -> [ProjectRelocationRecoveryStatus] {
    do {
      return try withMutationLock {
        let directory = journalDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
          .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var statuses: [ProjectRelocationRecoveryStatus] = []
        for file in files {
          do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            let sourceExists = fileManager.fileExists(atPath: journal.plan.sourcePath)
            let destinationExists = fileManager.fileExists(atPath: journal.plan.destinationPath)
            switch (sourceExists, destinationExists, journal.phase) {
            case (true, false, _):
              guard try identityToken(at: journal.plan.sourcePath) == journal.plan.sourceIdentity
              else { throw ProjectRelocationError.recoveryFailed }
              try archiveJournal(file, disposition: "abandoned")
              statuses.append(
                ProjectRelocationRecoveryStatus(
                  operationID: journal.request.operationID,
                  disposition: .abandonedBeforeCommit,
                  detail: "source remained authoritative"))
            case (false, true, _):
              guard
                try identityToken(at: journal.plan.destinationPath) == journal.plan.sourceIdentity
              else { throw ProjectRelocationError.recoveryFailed }
              try persistence.completeProjectRelocation(
                from: journal.plan.sourcePath,
                to: journal.plan.destinationPath,
                graph: journal.graph,
                supportSourcePath: journal.request.sourcePath)
              let result = ProjectRelocationResult(
                operationID: journal.request.operationID,
                sourcePath: journal.plan.sourcePath,
                destinationPath: journal.plan.destinationPath,
                sourceIdentity: journal.plan.sourceIdentity,
                graphRevision: journal.request.expectedGraphRevision)
              try writeReceipt(
                Receipt(
                  request: journal.request,
                  authorizedClientID: journal.authorizedClientID,
                  result: result))
              try archiveJournal(file, disposition: "recovered")
              statuses.append(
                ProjectRelocationRecoveryStatus(
                  operationID: journal.request.operationID,
                  disposition: .recovered,
                  detail: "destination support state completed"))
            default:
              throw ProjectRelocationError.recoveryFailed
            }
          } catch {
            let operationID =
              (try? JSONDecoder().decode(
                Journal.self, from: Data(contentsOf: file)))?.request.operationID
            do {
              try quarantineJournal(file)
            } catch {
              // Leave the original journal in place when even quarantine cannot be proven.
            }
            statuses.append(
              ProjectRelocationRecoveryStatus(
                operationID: operationID,
                disposition: .quarantined,
                detail: String(describing: error)))
          }
        }
        return statuses
      }
    } catch {
      return [
        ProjectRelocationRecoveryStatus(
          operationID: nil,
          disposition: .quarantined,
          detail: String(describing: error))
      ]
    }
  }

  private func preflight(
    operationID: UUID,
    sourcePath: String,
    destinationPath: String,
    graphRevision: Int,
    persistence: ProjectPersistence
  ) throws -> ProjectRelocationPlan {
    let canonicalSource: String
    let canonicalDestination: String
    do {
      canonicalSource = try platformPaths.canonicalProjectPath(sourcePath)
      canonicalDestination = try platformPaths.canonicalProjectPath(destinationPath)
    } catch {
      throw ProjectRelocationError.unsafePath
    }
    guard pathEquals(sourcePath, canonicalSource),
      pathEquals(destinationPath, canonicalDestination)
    else {
      throw ProjectRelocationError.unsafePath
    }
    guard !pathEquals(canonicalSource, canonicalDestination),
      !isNested(canonicalSource, in: canonicalDestination),
      !isNested(canonicalDestination, in: canonicalSource),
      !pathEquals(canonicalSource, supportDirectory.path),
      !pathEquals(canonicalDestination, supportDirectory.path),
      !isNested(canonicalSource, in: supportDirectory.path),
      !isNested(canonicalDestination, in: supportDirectory.path),
      !isNested(supportDirectory.path, in: canonicalSource),
      !isNested(supportDirectory.path, in: canonicalDestination),
      !pathEquals(canonicalSource, fileManager.homeDirectoryForCurrentUser.path),
      !pathEquals(canonicalDestination, fileManager.homeDirectoryForCurrentUser.path)
    else {
      throw ProjectRelocationError.unsafePath
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: canonicalSource, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ProjectRelocationError.sourceMissing
    }
    guard !fileManager.fileExists(atPath: canonicalDestination) else {
      throw ProjectRelocationError.destinationCollision
    }
    let destinationURL = URL(fileURLWithPath: canonicalDestination, isDirectory: true)
    let parent = destinationURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ProjectRelocationError.unsafePath
    }
    if try hasCaseCollision(destinationURL) {
      throw ProjectRelocationError.destinationCollision
    }
    try StableProjectDirectory.inspectDestinationParent(parent.path)
    guard fileManager.isWritableFile(atPath: parent.path),
      fileManager.isWritableFile(
        atPath: URL(fileURLWithPath: canonicalSource).deletingLastPathComponent().path)
    else {
      throw ProjectRelocationError.permissionDenied
    }
    guard try volumeIdentity(at: canonicalSource) == volumeIdentity(at: parent.path) else {
      throw ProjectRelocationError.crossVolume
    }
    guard !containsWorktreeTopology(at: canonicalSource) else {
      throw ProjectRelocationError.activeWorktrees
    }
    try persistence.preflightProjectRelocationDestination(canonicalDestination)
    try preflightRelocationState(
      destinationPath: canonicalDestination,
      excluding: operationID)
    return ProjectRelocationPlan(
      operationID: operationID,
      sourcePath: canonicalSource,
      destinationPath: canonicalDestination,
      sourceIdentity: try StableProjectDirectory(path: canonicalSource).identityToken,
      graphRevision: graphRevision)
  }

  private func preflightRelocationState(
    destinationPath: String,
    excluding operationID: UUID
  ) throws {
    if fileManager.fileExists(atPath: journalDirectory.path) {
      for file in try fileManager.contentsOfDirectory(
        at: journalDirectory, includingPropertiesForKeys: nil)
      where file.pathExtension == "json" {
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
        guard journal.request.operationID != operationID else { continue }
        if pathEquals(journal.plan.sourcePath, destinationPath)
          || pathEquals(journal.plan.destinationPath, destinationPath)
        {
          throw ProjectRelocationError.destinationCollision
        }
      }
    }
    if fileManager.fileExists(atPath: receiptDirectory.path) {
      for file in try fileManager.contentsOfDirectory(
        at: receiptDirectory, includingPropertiesForKeys: nil)
      where file.pathExtension == "json" {
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
        guard receipt.request.operationID != operationID else { continue }
        if pathEquals(receipt.result.sourcePath, destinationPath)
          || pathEquals(receipt.result.destinationPath, destinationPath)
        {
          throw ProjectRelocationError.destinationCollision
        }
      }
    }
  }

  private func containsWorktreeTopology(at path: String) -> Bool {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let dotGit = root.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
      if !isDirectory.boolValue { return true }
      if fileManager.fileExists(
        atPath: dotGit.appendingPathComponent("worktrees", isDirectory: true).path)
      {
        return true
      }
    }
    return fileManager.fileExists(atPath: root.appendingPathComponent(".gitmodules").path)
  }

  private func identityToken(at path: String) throws -> String {
    try StableProjectDirectory(path: path).identityToken
  }

  private func volumeIdentity(at path: String) throws -> String {
    let attributes = try fileManager.attributesOfItem(atPath: path)
    guard let value = attributes[.systemNumber] else {
      throw ProjectRelocationError.preflightFailed
    }
    return String(describing: value)
  }

  private func hasCaseCollision(_ destination: URL) throws -> Bool {
    let target = destination.lastPathComponent
    return try fileManager.contentsOfDirectory(
      at: destination.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    ).contains {
      $0.lastPathComponent.caseInsensitiveCompare(target) == .orderedSame
    }
  }

  private func isNested(_ candidate: String, in parent: String) -> Bool {
    let candidate = normalized(candidate)
    let parent = normalized(parent)
    return candidate.hasPrefix(parent + separator(for: parent))
  }

  private func pathEquals(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  private func normalized(_ path: String) -> String {
    let value = path.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    #if os(Windows)
      return value.lowercased()
    #else
      return value
    #endif
  }

  private func separator(for path: String) -> String {
    path.contains("\\") ? "\\" : "/"
  }

  private var journalDirectory: URL {
    supportDirectory.appendingPathComponent("project-relocations", isDirectory: true)
      .appendingPathComponent("journals", isDirectory: true)
  }

  private var receiptDirectory: URL {
    supportDirectory.appendingPathComponent("project-relocations", isDirectory: true)
      .appendingPathComponent("receipts", isDirectory: true)
  }

  private func journalURL(_ id: UUID) -> URL {
    journalDirectory.appendingPathComponent("\(id.uuidString).json")
  }

  private func receiptURL(_ id: UUID) -> URL {
    receiptDirectory.appendingPathComponent("\(id.uuidString).json")
  }

  private func writeJournal(_ journal: Journal) throws {
    try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    try writeDurably(JSONEncoder().encode(journal), to: journalURL(journal.request.operationID))
  }

  private func removeJournal(_ id: UUID) throws {
    let url = journalURL(id)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  private func writeReceipt(_ receipt: Receipt) throws {
    try fileManager.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
    try writeDurably(
      JSONEncoder().encode(receipt), to: receiptURL(receipt.request.operationID))
  }

  private func writeDurably(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  private func loadReceipt(_ id: UUID) throws -> Receipt? {
    let url = receiptURL(id)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
  }

  private var recoveryArchiveDirectory: URL {
    supportDirectory.appendingPathComponent("project-relocations", isDirectory: true)
      .appendingPathComponent("recovered", isDirectory: true)
  }

  private var recoveryQuarantineDirectory: URL {
    supportDirectory.appendingPathComponent("project-relocations", isDirectory: true)
      .appendingPathComponent("quarantine", isDirectory: true)
  }

  private func archiveJournal(_ file: URL, disposition: String) throws {
    try moveRecoveryEvidence(
      file,
      to: recoveryArchiveDirectory.appendingPathComponent(
        "\(file.deletingPathExtension().lastPathComponent)-\(disposition).json"))
  }

  private func quarantineJournal(_ file: URL) throws {
    try moveRecoveryEvidence(
      file,
      to: recoveryQuarantineDirectory.appendingPathComponent(file.lastPathComponent))
  }

  private func moveRecoveryEvidence(_ source: URL, to destination: URL) throws {
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ProjectRelocationError.recoveryFailed
    }
    try fileManager.moveItem(at: source, to: destination)
  }

  private func mapFilesystemError(_ error: Error) -> ProjectRelocationError {
    let cocoa = error as NSError
    if cocoa.domain == NSCocoaErrorDomain,
      cocoa.code == NSFileWriteNoPermissionError || cocoa.code == NSFileReadNoPermissionError
    {
      return .permissionDenied
    }
    if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileWriteFileExistsError {
      return .destinationCollision
    }
    if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileNoSuchFileError {
      return .sourceMissing
    }
    return .preflightFailed
  }

  private func withMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
    Self.processLock.lock()
    defer { Self.processLock.unlock() }
    return try operation()
  }
}
