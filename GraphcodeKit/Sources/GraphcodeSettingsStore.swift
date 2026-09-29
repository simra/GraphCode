import Foundation

/// Where `GraphcodeSettings` lives: `~/.graphcode/settings.json`.
///
/// A file rather than `UserDefaults`, because the **daemon** is what builds a session's
/// launch command and it is a different process with a different domain — settings kept in
/// the app's defaults would be invisible to the thing they configure.
///
/// Read fresh on every use rather than cached. A session starts once every few minutes at
/// most, so the read costs nothing measurable, and it means changing a setting in the app
/// applies to the next loop the daemon starts without restarting anything.
public enum GraphcodeSettingsStore {
  enum StoreError: Error, Equatable, Sendable {
    case unreadable(String)
    case corrupt(String)
    case invalidShape
    case conflict(currentRevision: String)
    case encodingFailed(String)
    case writeFailed(String)
    case payloadTooLarge
  }

  static let maxDocumentBytes = FramedMessageIO.v2MaxPayloadBytes / 2

  public static var url: URL {
    SupportDirectory.url.appendingPathComponent("settings.json")
  }

  /// Never throws and never returns nothing. A missing file is the first launch; a
  /// corrupt one is someone's hand-edit or a half-written save. Both mean "use the
  /// defaults" — refusing to start sessions because a preferences file didn't parse
  /// would be a far worse failure than quietly ignoring it.
  public static func load(from url: URL = GraphcodeSettingsStore.url) -> GraphcodeSettings {
    (try? snapshot(from: url).settings) ?? GraphcodeSettings()
  }

  static func snapshot(
    from url: URL = GraphcodeSettingsStore.url
  ) throws -> GraphcodeSettingsSnapshot {
    let document = try readDocument(from: url)
    return GraphcodeSettingsSnapshot(
      settings: try decodeSettings(from: document.data, exists: document.exists),
      revision: revision(of: document.data),
      exists: document.exists,
      supportDirectory: url.deletingLastPathComponent().path,
      filePath: url.path)
  }

  static func update(
    _ settings: GraphcodeSettings,
    expectedRevision: String,
    at url: URL = GraphcodeSettingsStore.url
  ) throws -> GraphcodeSettingsSnapshot {
    let document = try readDocument(from: url)
    let currentRevision = revision(of: document.data)
    guard currentRevision == expectedRevision else {
      throw StoreError.conflict(currentRevision: currentRevision)
    }
    var object = try decodeObject(from: document.data, exists: document.exists)
    let canonical = try encodedObject(settings)
    for (key, value) in canonical {
      object[key] = value
    }
    let data: Data
    do {
      data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    } catch {
      throw StoreError.encodingFailed(error.localizedDescription)
    }
    guard data.count <= maxDocumentBytes else { throw StoreError.payloadTooLarge }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }
    return GraphcodeSettingsSnapshot(
      settings: settings, revision: revision(of: data), exists: true,
      supportDirectory: url.deletingLastPathComponent().path,
      filePath: url.path)
  }

  /// Changes one setting on disk, reading and writing in one step.
  ///
  /// Exists because the app's live `SettingsModel` is a singleton whose first touch in a
  /// freshly launched instance may be the very effect trying to write through it — the
  /// new-workspace starter's, which asks which agent runs this workspace's loops before
  /// anything else has read a setting. Going straight to the file removes that ordering
  /// from the answer: the pick lands whether or not anything has looked at settings yet,
  /// and the caller syncs the live model afterwards.
  @discardableResult
  static func setDefaultBackend(
    _ backend: CLISessionBackendKind, to url: URL = GraphcodeSettingsStore.url
  ) -> Bool {
    var settings = load(from: url)
    settings.defaultBackend = backend
    return save(settings, to: url)
  }

  @discardableResult
  static func save(
    _ settings: GraphcodeSettings, to url: URL = GraphcodeSettingsStore.url
  ) -> Bool {
    let encoder = JSONEncoder()
    // Sorted and indented because this file is meant to be readable — and editable — by
    // the person whose machine it is.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(settings) else { return false }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func readDocument(from url: URL) throws -> (data: Data, exists: Bool) {
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= maxDocumentBytes else { throw StoreError.payloadTooLarge }
      return (data, true)
    } catch let error as StoreError {
      throw error
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return (Data(), false)
    } catch {
      throw StoreError.unreadable(error.localizedDescription)
    }
  }

  private static func decodeSettings(from data: Data, exists: Bool) throws -> GraphcodeSettings {
    guard exists else { return GraphcodeSettings() }
    do {
      return try JSONDecoder().decode(GraphcodeSettings.self, from: data)
    } catch {
      throw StoreError.corrupt(error.localizedDescription)
    }
  }

  private static func decodeObject(
    from data: Data, exists: Bool
  ) throws -> [String: Any] {
    guard exists else { return [:] }
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw StoreError.corrupt(error.localizedDescription)
    }
    guard let object = value as? [String: Any] else { throw StoreError.invalidShape }
    _ = try decodeSettings(from: data, exists: true)
    return object
  }

  private static func encodedObject(_ settings: GraphcodeSettings) throws -> [String: Any] {
    do {
      let data = try JSONEncoder().encode(settings)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StoreError.invalidShape
      }
      return object
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.encodingFailed(error.localizedDescription)
    }
  }

  private static func revision(of data: Data) -> String {
    GraphcodeSHA256.hex(data)
  }
}
