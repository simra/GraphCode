import Foundation

/// Persists graphs off the actor that changes them — the disk-side twin of
/// `OutboundChannel` (issue #307).
///
/// `GraphStore.broadcast()` used to call `persistence.saveGraph` synchronously, so every
/// mutation held the `GraphStore` actor across a full serialise-and-write — the shape
/// #291 removed from the socket path, one layer over: a memo measured at 0.03–2.13 s
/// against a 0.003 s socket round trip, with the variance coming from the filesystem.
///
/// A save is handed here and the actor returns. One serial queue writes; consecutive
/// unacknowledged saves of the same project collapse to the newest snapshot (the graph
/// is a value and the file is a whole, so nothing older has anything left to say), which
/// turns a burst of memos into one write. Acknowledged saves are ordering barriers and
/// cannot be replaced by later snapshots. `flush` waits for everything queued — what the
/// daemon calls on its way out, and what a test calls before reading the file back.
public final class GraphWriter: @unchecked Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case persistenceFailed(String)
    case relocationInProgress
  }

  private struct PendingWrite {
    var graph: LoopGraph
    var acknowledgements: [@Sendable (Result<Void, Failure>) -> Void]
  }

  private let persistence: ProjectPersistence
  private let beforeWrite: @Sendable (LoopGraph) -> Void
  private let queue = DispatchQueue(label: "dev.graphcode.graphcoded.persist", qos: .utility)
  private let lock = NSLock()
  private var pending: [String: [PendingWrite]] = [:]
  private var relocationBlockedPaths: Set<String> = []
  private var scheduled = false

  public init(
    persistence: ProjectPersistence,
    beforeWrite: @escaping @Sendable (LoopGraph) -> Void = { _ in }
  ) {
    self.persistence = persistence
    self.beforeWrite = beforeWrite
  }

  /// Queues the newest snapshot of a project and returns at once.
  public func save(_ graph: LoopGraph) {
    lock.lock()
    guard !relocationBlockedPaths.contains(graph.project.path) else {
      lock.unlock()
      return
    }
    if var writes = pending[graph.project.path], var existing = writes.last,
      existing.acknowledgements.isEmpty
    {
      existing.graph = graph
      writes[writes.count - 1] = existing
      pending[graph.project.path] = writes
    } else {
      pending[graph.project.path, default: []].append(
        PendingWrite(graph: graph, acknowledgements: []))
    }
    let drainNeeded = !scheduled
    scheduled = true
    lock.unlock()
    guard drainNeeded else { return }
    queue.async { [self] in drain() }
  }

  /// Queues a graph and resumes only after the serial writer has atomically persisted
  /// it. Every acknowledgement attached to a coalesced write observes that write's
  /// success or failure.
  public func saveAcknowledged(_ graph: LoopGraph) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      lock.lock()
      guard !relocationBlockedPaths.contains(graph.project.path) else {
        lock.unlock()
        continuation.resume(throwing: Failure.relocationInProgress)
        return
      }
      let acknowledge: @Sendable (Result<Void, Failure>) -> Void = { result in
        continuation.resume(with: result)
      }
      if var writes = pending[graph.project.path], var existing = writes.last,
        existing.acknowledgements.isEmpty
      {
        existing.graph = graph
        existing.acknowledgements.append(acknowledge)
        writes[writes.count - 1] = existing
        pending[graph.project.path] = writes
      } else {
        pending[graph.project.path, default: []].append(
          PendingWrite(graph: graph, acknowledgements: [acknowledge]))
      }
      let drainNeeded = !scheduled
      scheduled = true
      lock.unlock()
      if drainNeeded {
        queue.async { [self] in drain() }
      }
    }
  }

  /// The newest snapshot of a project — the one still queued, if there is one, else
  /// the file. Every reader of the persisted graph goes through here rather than
  /// through the file: a save that has left the actor and not yet reached the disk is
  /// otherwise invisible, and a delete of a *closed* project (no live store) that read
  /// the file to find the loops whose sessions it must end would end fewer than exist
  /// and leave the rest running.
  public func load(path: String) -> LoopGraph? {
    lock.lock()
    let queued = pending[path]?.last?.graph
    lock.unlock()
    if let queued { return queued }
    return persistence.loadGraph(path: path)
  }

  /// Drops any save still queued for a project, for a caller that is about to delete it.
  ///
  /// The queue exists to let a write land after the actor has moved on, which is exactly
  /// wrong once the graph is being thrown away: a drain that ran after `deleteGraph`
  /// would put the file back, and `load` would keep answering from the queue for a
  /// project that no longer exists. The delete is the one operation that has to reach
  /// into the queue rather than trail it.
  ///
  /// Synced against the drain, not just the pending table: a drain that has already
  /// popped a save still has the write ahead of it — a write made outside the lock, and
  /// one that would land after `deleteGraph` removed the file. Only the drain's
  /// completion makes "nothing queued" true, and the serial queue is where that
  /// ordering lives.
  public func forget(path: String) {
    queue.sync {
      lock.lock()
      let abandoned = pending.removeValue(forKey: path)
      lock.unlock()
      for write in abandoned ?? [] {
        for acknowledge in write.acknowledgements {
          acknowledge(.failure(.persistenceFailed("graph was deleted before its save completed")))
        }
      }
    }
  }

  public func deleteAcknowledged(path: String) throws {
    lock.lock()
    relocationBlockedPaths.insert(path)
    lock.unlock()
    do {
      try queue.sync {
        drain()
        try persistence.deleteGraphAcknowledged(path: path)
      }
    } catch {
      lock.lock()
      relocationBlockedPaths.remove(path)
      lock.unlock()
      throw error
    }
  }

  public func allowWritesAfterDeletion(path: String) {
    lock.lock()
    relocationBlockedPaths.remove(path)
    lock.unlock()
  }

  /// Blocks new old-path saves and returns only after every save accepted before the
  /// block has reached disk. Relocation calls this while the graph lease is held.
  public func beginRelocation(path: String) {
    lock.lock()
    relocationBlockedPaths.insert(path)
    lock.unlock()
    queue.sync { drain() }
  }

  /// A pre-commit failure or verified rollback makes the old path writable again.
  public func cancelRelocation(path: String) {
    lock.lock()
    relocationBlockedPaths.remove(path)
    lock.unlock()
  }

  /// Returns once everything queued so far is on disk.
  public func flush() {
    queue.sync { drain() }
  }

  private func drain() {
    while true {
      lock.lock()
      guard let (path, writes) = pending.first, let write = writes.first else {
        scheduled = false
        lock.unlock()
        return
      }
      if writes.count == 1 {
        pending.removeValue(forKey: path)
      } else {
        pending[path] = Array(writes.dropFirst())
      }
      lock.unlock()
      beforeWrite(write.graph)
      do {
        try persistence.saveGraphAcknowledged(write.graph)
        for acknowledge in write.acknowledgements { acknowledge(.success(())) }
      } catch {
        let failure = Failure.persistenceFailed(String(describing: error))
        for acknowledge in write.acknowledgements { acknowledge(.failure(failure)) }
        if !write.acknowledgements.isEmpty {
          lock.lock()
          let invalidated = pending.removeValue(forKey: path) ?? []
          lock.unlock()
          for pendingWrite in invalidated {
            for acknowledge in pendingWrite.acknowledgements {
              acknowledge(.failure(failure))
            }
          }
        }
      }
    }
  }
}
