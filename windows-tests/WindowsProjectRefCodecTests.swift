import Foundation
import XCTest

@testable import GraphcodeKit

final class WindowsProjectRefCodecTests: XCTestCase {
  private struct LegacyProjectRef: Decodable {
    let path: String
    let name: String
    let lastOpenedAt: Date
  }

  func testLegacyProjectRefDecodesWithoutMetadata() throws {
    let data = Data(#"{"path":"C:\\synthetic\\same","name":"Legacy","lastOpenedAt":0}"#.utf8)
    let project = try JSONDecoder().decode(ProjectRef.self, from: data)

    XCTAssertEqual(project.path, "C:\\synthetic\\same")
    XCTAssertNil(project.metadata)
  }

  func testLegacyClientShapeIgnoresMetadataAndMissingCapabilitiesFailClosed() throws {
    let encoded = try JSONEncoder().encode(
      ProjectRef(path: "C:\\synthetic\\same", name: "Current", metadata: .local))
    let legacy = try JSONDecoder().decode(LegacyProjectRef.self, from: encoded)

    XCTAssertEqual(legacy.path, "C:\\synthetic\\same")
    XCTAssertEqual(legacy.name, "Current")

    let partial = Data(
      #"""
      {
        "path": "C:\\synthetic\\same",
        "name": "Partial",
        "lastOpenedAt": 0,
        "metadata": {
          "location": "ssh",
          "capabilities": { "diagnostics": true }
        }
      }
      """#.utf8)
    let decoded = try JSONDecoder().decode(ProjectRef.self, from: partial)

    XCTAssertEqual(decoded.metadata?.location, .ssh)
    XCTAssertTrue(decoded.metadata?.capabilities.diagnostics == true)
    XCTAssertFalse(decoded.metadata?.capabilities.revealInFileManager == true)
    XCTAssertFalse(decoded.metadata?.capabilities.templates == true)
    XCTAssertFalse(decoded.metadata?.capabilities.attachments == true)
    XCTAssertFalse(decoded.metadata?.capabilities.interactiveTerminals == true)
  }

  func testFutureAndMalformedMetadataDoNotRejectGraphsOrRecentArrays() throws {
    let project = ProjectRef(path: "C:\\synthetic\\same", name: "Safe", metadata: .local)
    let graph = LoopGraph(project: project)

    var graphJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)) as? [String: Any])
    var graphProject = try XCTUnwrap(graphJSON["project"] as? [String: Any])
    graphProject["metadata"] = [
      "location": "futureRemote",
      "capabilities": ["interactiveTerminals": true],
    ]
    graphJSON["project"] = graphProject
    let futureGraph = try JSONDecoder().decode(
      LoopGraph.self,
      from: JSONSerialization.data(withJSONObject: graphJSON))

    XCTAssertEqual(futureGraph.project.path, project.path)
    XCTAssertEqual(futureGraph.project.name, project.name)
    XCTAssertNil(futureGraph.project.metadata)

    var recentJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode([project])) as? [[String: Any]])
    recentJSON[0]["metadata"] = ["location": "ssh", "capabilities": "malformed"]
    let recent = try JSONDecoder().decode(
      [ProjectRef].self,
      from: JSONSerialization.data(withJSONObject: recentJSON))

    XCTAssertEqual(recent.count, 1)
    XCTAssertEqual(recent[0].path, project.path)
    XCTAssertEqual(recent[0].name, project.name)
    XCTAssertNil(recent[0].metadata)
  }

  func testIdenticalLookingPathsRetainAuthoritativeLocationMetadata() throws {
    let path = "C:\\synthetic\\same"
    let local = ProjectRef(path: path, name: "Same", metadata: .local)
    let ssh = ProjectRef(path: path, name: "Same", metadata: .ssh)
    let codespace = ProjectRef(path: path, name: "Same", metadata: .codespace)

    XCTAssertEqual(local.path, ssh.path)
    XCTAssertEqual(ssh.path, codespace.path)
    XCTAssertEqual(local.metadata?.location, .local)
    XCTAssertEqual(ssh.metadata?.location, .ssh)
    XCTAssertEqual(codespace.metadata?.location, .codespace)
    XCTAssertTrue(local.metadata?.capabilities.interactiveTerminals == true)
    XCTAssertFalse(ssh.metadata?.capabilities.interactiveTerminals == true)
    XCTAssertFalse(codespace.metadata?.capabilities.interactiveTerminals == true)
  }

  func testRootInvariantPreservesNestedDisplayAndNonGlobalScope() throws {
    let nested = LoopGraph(
      project: ProjectRef(path: "", name: "Nested display", metadata: .local))
    let node = LoopNode(title: "Composite", loopType: .composite, subGraph: nested)
    let remoteRoot = ProjectRef(
      path: "C:\\synthetic\\same",
      name: "Root display",
      metadata: .ssh)
    let normalized = LoopGraph(project: remoteRoot, nodes: [node])
      .enforcingRootProject(remoteRoot)
    let normalizedNested = try XCTUnwrap(normalized.nodes.first?.subGraph)

    XCTAssertEqual(normalizedNested.project.path, remoteRoot.path)
    XCTAssertEqual(normalizedNested.project.name, "Nested display")
    XCTAssertEqual(normalizedNested.project.metadata, .ssh)
    XCTAssertFalse(normalizedNested.isGlobal)

    let globalRoot = ProjectRef(path: LoopGraphScope.globalPath, name: "Global")
    let globalNormalized = LoopGraph(scope: .global, nodes: [node])
      .enforcingRootProject(globalRoot)
    let globalNested = try XCTUnwrap(globalNormalized.nodes.first?.subGraph)

    XCTAssertTrue(globalNormalized.isGlobal)
    XCTAssertFalse(globalNested.isGlobal)
    XCTAssertEqual(globalNested.project.path, LoopGraphScope.globalPath)
    XCTAssertEqual(globalNested.project.name, "Nested display")
    XCTAssertNil(globalNested.project.metadata)
  }

  func testEncodedMetadataContainsNoConnectionDetails() throws {
    let location = RemoteProjectLocation(
      user: "sensitive-user",
      host: "sensitive-host",
      port: 2222,
      remotePath: "/synthetic/repository")
    let project = ProjectRef(
      path: "C:\\synthetic\\same",
      name: "Same",
      metadata: ProjectMetadata.inferred(fromProjectPath: location.projectPath))
    let json = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)

    XCTAssertTrue(json.contains(#""location":"ssh""#))
    XCTAssertFalse(json.contains("sensitive-user"))
    XCTAssertFalse(json.contains("sensitive-host"))
    XCTAssertFalse(json.contains("2222"))
    XCTAssertFalse(json.contains("repository"))
    XCTAssertFalse(json.contains("token"))
    XCTAssertFalse(json.contains("repoURL"))
  }

  func testGraphCodecPreservesProjectRefsAcrossRepeatedRoundTrips() throws {
    let rootDate = Date(timeIntervalSinceReferenceDate: 812133256.5609074)
    let nestedDate = Date(timeIntervalSinceReferenceDate: 812133256.5608349)
    let nodeDate = Date(timeIntervalSinceReferenceDate: 812133256.5604343)
    let rootRef = ProjectRef(
      path: "C:\\synthetic\\source project",
      name: "source",
      lastOpenedAt: rootDate,
      metadata: .local)
    let nestedRef = ProjectRef(path: rootRef.path, name: "nested", lastOpenedAt: nestedDate)
    let child = LoopNode(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      title: "Nested fixture", loopType: .turnBased, checkDescription: "Keep these notes",
      firstInstruction: "Nested configuration\nand notes", state: .succeeded, createdAt: nodeDate)
    let nested = LoopGraph(
      id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      scope: .project(nestedRef), nodes: [child])
    let parent = LoopNode(
      id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      title: "Composite fixture", loopType: .composite, subGraph: nested,
      state: .succeeded, createdAt: nodeDate)
    let peer = LoopNode(
      id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      title: "Conversation fixture", loopType: .turnBased, firstInstruction: "Preserve me",
      backend: .copilotCLI, state: .succeeded, createdAt: nodeDate)
    let edge = LoopEdge(
      id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      from: parent.id, to: peer.id, payloadTransform: .template("notes {{output}}"))
    let expected = LoopGraph(
      id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
      scope: .project(rootRef), nodes: [parent, peer], edges: [edge])
    var current = expected
    for iteration in 1...3 {
      current = try JSONDecoder().decode(LoopGraph.self, from: JSONEncoder().encode(current))
      XCTAssertTrue(current == expected, "Full graph value changed on round trip \(iteration)")
      XCTAssertEqual(current.project.lastOpenedAt, rootDate)
      XCTAssertEqual(current.nodes[id: parent.id]?.subGraph?.project.lastOpenedAt, nestedDate)
      XCTAssertEqual(current.nodes[id: parent.id]?.subGraph?.nodes[id: child.id], child)
      XCTAssertEqual(current.nodes[id: peer.id], peer)
      XCTAssertEqual(current.edges[id: edge.id], edge)
    }
    let global = LoopGraph(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, scope: .global)
    let decodedGlobal = try JSONDecoder().decode(LoopGraph.self, from: JSONEncoder().encode(global))
    XCTAssertEqual(decodedGlobal.scope, .global)
    XCTAssertEqual(decodedGlobal, global)
  }
}
