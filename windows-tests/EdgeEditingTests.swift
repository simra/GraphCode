import Foundation
import IdentifiedCollections
import XCTest

@testable import GraphcodeKit

final class EdgeEditingTests: XCTestCase {
  private let source = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let target = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let edgeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private let parent = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
  private let sibling = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

  private func graph(
    spec: EdgeSpec = EdgeSpec(), count: Int = 4, targetState: LoopState = .idle
  ) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "edge-edit-inert", name: "Inert"),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(id: source, title: "Source", loopType: .turnBased, firstInstruction: "Work"),
        LoopNode(
          id: target, title: "Target", loopType: .turnBased,
          firstInstruction: "Work", state: targetState),
      ]),
      edges: IdentifiedArrayOf(uniqueElements: [
        LoopEdge(id: edgeID, from: source, to: target, spec: spec, fireCount: count)
      ]))
  }

  private func nested(_ child: LoopGraph) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "edge-edit-root", name: "Root"),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(
          id: parent, title: "Parent", loopType: .composite, subGraph: child,
          state: child.aggregateState),
        LoopNode(
          id: sibling, title: "Sibling", loopType: .composite, subGraph: child,
          state: child.aggregateState),
      ]))
  }

  private func command(_ before: EdgeSpec, _ after: EdgeSpec) -> GraphCommand {
    .updateEdge(id: edgeID, from: source, to: target, expectedSpec: before, spec: after)
  }

  private func rejected(
    _ result: GraphStoreCommandResult, containing text: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .rejected(let message, _) = result else {
      XCTFail("Expected rejected command", file: file, line: line)
      return
    }
    XCTAssertTrue(message.contains(text), message, file: file, line: line)
  }

  func testUpdatePreservesIdentityConfigurationAndCurrentRuntimeCount() async {
    let before = EdgeSpec(
      condition: .onFailure, payloadTransform: .template("quoted \"text\" \u{2603}"),
      cycleGuard: CycleGuard(maxIterations: 8, until: "  done  "),
      spawnTargetProjectPath: "C:\\quoted \"project\"")
    var after = before
    after.kind = .message
    let initial = graph(spec: before, count: 7)
    let store = GraphStore(graph: initial)
    _ = await store.handle(command(before, after))
    let updated = await store.graph
    XCTAssertEqual(updated.edges.count, 1)
    XCTAssertEqual(updated.edges[0].id, edgeID)
    XCTAssertEqual(updated.edges[0].from, source)
    XCTAssertEqual(updated.edges[0].to, target)
    XCTAssertEqual(updated.edges[0].fireCount, 7)
    XCTAssertTrue(updated.edges[0].fired)
    XCTAssertEqual(updated.edges[0].spec, after)
    XCTAssertEqual(updated.nodes, initial.nodes)
  }

  func testCASAndDuplicateKindRejectWithoutReplacingEdge() async {
    var initial = graph(count: 0)
    initial.edges.append(LoopEdge(from: source, to: target, kind: .message))
    let store = GraphStore(graph: initial)
    rejected(
      await store.handle(command(EdgeSpec(), EdgeSpec(kind: .message))), containing: "duplicate")
    let afterDuplicate = await store.graph
    XCTAssertEqual(afterDuplicate.edges, initial.edges)
    var changed = EdgeSpec()
    changed.condition = .onFailure
    _ = await store.handle(command(EdgeSpec(), changed))
    rejected(await store.handle(command(EdgeSpec(), EdgeSpec(kind: .spawn))), containing: "changed")
    let afterConflict = await store.graph
    XCTAssertEqual(afterConflict.edges[id: edgeID]?.spec, changed)
    XCTAssertEqual(afterConflict.edges[id: edgeID]?.fireCount, 0)
  }

  func testMissingEdgeEndpointsAndChangedIdentityAreRejected() async {
    var missingTarget = graph()
    missingTarget.nodes.remove(id: target)
    let endpointStore = GraphStore(graph: missingTarget)
    rejected(
      await endpointStore.handle(command(EdgeSpec(), EdgeSpec(kind: .spawn))),
      containing: "endpoints")
    let store = GraphStore(graph: graph())
    rejected(
      await store.handle(
        .updateEdge(
          id: edgeID, from: target, to: source, expectedSpec: EdgeSpec(), spec: EdgeSpec())),
      containing: "changed")
    rejected(
      await store.handle(
        .updateEdge(
          id: parent, from: source, to: target, expectedSpec: EdgeSpec(), spec: EdgeSpec())),
      containing: "no edge")
  }

  func testKindChangesRecomputeOnlyIdleOrBlockedReadiness() async {
    for state in [LoopState.idle, .blocked, .running, .succeeded] {
      for count in [0, 1] {
        let before = EdgeSpec(kind: .message)
        let store = GraphStore(graph: graph(spec: before, count: count, targetState: state))
        _ = await store.handle(command(before, EdgeSpec(kind: .handoff)))
        let blocked = await store.graph
        let expected: LoopState =
          (state == .idle || state == .blocked) ? (count == 0 ? .blocked : .idle) : state
        XCTAssertEqual(blocked.nodes[id: target]?.state, expected)
        XCTAssertEqual(blocked.edges[id: edgeID]?.fireCount, count)
        _ = await store.handle(command(EdgeSpec(kind: .handoff), EdgeSpec(kind: .spawn)))
        let unblocked = await store.graph
        XCTAssertEqual(
          unblocked.nodes[id: target]?.state,
          (state == .idle || state == .blocked) ? .idle : state)
        XCTAssertEqual(unblocked.edges[id: edgeID]?.fireCount, count)
      }
    }
    var initial = graph(count: 0, targetState: .blocked)
    initial.edges.append(LoopEdge(from: source, to: target))
    let store = GraphStore(graph: initial)
    _ = await store.handle(command(EdgeSpec(), EdgeSpec(kind: .message)))
    let remaining = await store.graph
    XCTAssertEqual(remaining.nodes[id: target]?.state, .blocked)
  }

  func testUnchangedLegacyGuardsSurviveButChangedInvalidGuardsReject() async {
    let guards: [CycleGuard?] = [
      nil, CycleGuard(), CycleGuard(until: ""),
      CycleGuard(maxIterations: -3, until: "", stopAfterPassesWithoutImprovement: 0),
    ]
    for guardValue in guards {
      let before = EdgeSpec(cycleGuard: guardValue)
      var after = before
      after.condition = .onFailure
      let store = GraphStore(graph: graph(spec: before))
      _ = await store.handle(command(before, after))
      let retained = await store.graph
      XCTAssertEqual(retained.edges[0].cycleGuard, guardValue)
      var invalid = after
      invalid.cycleGuard = CycleGuard(maxIterations: -99)
      rejected(await store.handle(command(after, invalid)), containing: "bounded")
      var cleared = after
      cleared.cycleGuard = nil
      _ = await store.handle(command(after, cleared))
      let updated = await store.graph
      XCTAssertNil(updated.edges[0].cycleGuard)
      XCTAssertEqual(updated.edges[0].fireCount, 4)
    }
  }

  func testDirectCompositePublishesRootAndKeepsSiblingAndRollup() async {
    let child = graph(count: 0, targetState: .blocked)
    let initial = nested(child)
    let snapshots = EdgeEditSnapshots()
    let store = GraphStore(graph: initial, onGraphChanged: { snapshots.append($0) })
    _ = await store.handle(
      .subGraphCommand(
        nodeID: parent,
        command: command(EdgeSpec(), EdgeSpec(kind: .message))))
    let updated = await store.graph
    XCTAssertEqual(updated.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.kind, .message)
    XCTAssertEqual(updated.nodes[id: parent]?.subGraph?.nodes[id: target]?.state, .idle)
    XCTAssertEqual(updated.nodes[id: parent]?.state, .idle)
    let normalized = initial.enforcingRootProject(initial.project)
    XCTAssertEqual(updated.nodes[id: sibling], normalized.nodes[id: sibling])
    XCTAssertEqual(snapshots.values.count, 1)
    XCTAssertEqual(snapshots.values.first?.project.path, "edge-edit-root")
    XCTAssertEqual(
      snapshots.values.first?.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.kind, .message)
  }

  func testWrongAndDeeperEditScopesRejectWithoutLegacyFallback() async {
    let initial = nested(graph())
    let store = GraphStore(graph: initial)
    rejected(
      await store.handle(command(EdgeSpec(), EdgeSpec(kind: .message))), containing: "no edge")
    rejected(
      await store.handle(
        .subGraphCommand(
          nodeID: target,
          command: command(EdgeSpec(), EdgeSpec()))), containing: "direct composite")
    rejected(
      await store.handle(
        .subGraphCommand(
          nodeID: parent,
          command: .subGraphCommand(nodeID: sibling, command: command(EdgeSpec(), EdgeSpec())))),
      containing: "one direct composite")
    let updated = await store.graph
    XCTAssertEqual(updated.nodes, initial.enforcingRootProject(initial.project).nodes)
  }

  func testV2PreviewRejectsBeforeMutationOrPublication() async {
    let initial = nested(graph())
    let snapshots = EdgeEditSnapshots()
    let store = GraphStore(graph: initial, onGraphChanged: { snapshots.append($0) })
    rejected(
      await store.handle(
        .subGraphCommand(
          nodeID: parent,
          command: command(EdgeSpec(), EdgeSpec(kind: .message))), v2PayloadLimit: 1),
      containing: "payload limit")
    let updated = await store.graph
    XCTAssertEqual(updated.nodes, initial.enforcingRootProject(initial.project).nodes)
    XCTAssertTrue(snapshots.values.isEmpty)
  }

  func testQueuedLegacyChildWritebackCompletesBeforeCheckedEditPreservesProgress() async {
    let before = EdgeSpec(
      kind: .message, payloadTransform: .template("inert"),
      cycleGuard: CycleGuard(maxIterations: 8))
    var after = before
    after.kind = .handoff
    let initial = nested(graph(spec: before, count: 4, targetState: .running))
    let entered = expectation(description: "legacy child reached inert delivery")
    let release = EdgeEditGate()
    let snapshots = EdgeEditSnapshots()
    let store = GraphStore(
      graph: initial, onGraphChanged: { snapshots.append($0) },
      onDeliverMessage: { _, _, _ in
        entered.fulfill()
        await release.wait()
        return true
      })
    let parentID = parent
    let sourceID = source
    let edit = command(before, after)
    let legacy = Task {
      await store.handle(.subGraphCommand(nodeID: parentID, command: .nodeCheckApproved(sourceID)))
    }
    await fulfillment(of: [entered], timeout: 5)
    let pending = Task {
      await store.handle(
        .subGraphCommand(nodeID: parentID, command: edit), v2PayloadLimit: 1_000_000)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if await store.queuedCommandSequence >= 2 { break }
      await Task.yield()
    }
    let admitted = await store.queuedCommandSequence
    let stillUnpublished = snapshots.values.isEmpty
    await release.open()
    _ = await legacy.value
    _ = await pending.value
    XCTAssertEqual(admitted, 2)
    XCTAssertTrue(stillUnpublished)
    let updated = await store.graph
    XCTAssertEqual(updated.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.fireCount, 5)
    XCTAssertEqual(updated.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.spec, after)
    let normalized = initial.enforcingRootProject(initial.project)
    XCTAssertEqual(updated.nodes[id: sibling], normalized.nodes[id: sibling])
    XCTAssertEqual(snapshots.values.count, 2)
    XCTAssertEqual(
      snapshots.values.first?.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.kind, .message)
    XCTAssertEqual(
      snapshots.values.last?.nodes[id: parent]?.subGraph?.edges[id: edgeID]?.kind, .handoff)
  }
}

private final class EdgeEditSnapshots: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LoopGraph] = []
  func append(_ graph: LoopGraph) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(graph)
  }
  var values: [LoopGraph] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private actor EdgeEditGate {
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if opened { return }
    await withCheckedContinuation { self.continuation = $0 }
  }
  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}
