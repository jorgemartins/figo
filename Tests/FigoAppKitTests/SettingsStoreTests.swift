import Foundation
import Testing

@testable import FigoAppKit

@MainActor
@Suite final class SettingsStoreTests {
  let directory: URL
  let file: URL

  init() throws {
    directory = try makeTemporaryDirectory("settings")
    file = directory.appendingPathComponent("settings.json")
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  private func write(_ text: String) throws {
    try Data(text.utf8).write(to: file)
  }

  @Test func missingFileMeansNoSettings() {
    let store = SettingsStore(fileURL: file)
    #expect(store.reload().isEmpty)
    #expect(store.values.isEmpty)
  }

  @Test func readsAFlatMapWithDottedKeys() throws {
    try write(#"{"autocomplete.height": 200, "autocomplete.disable": true, "autocomplete.theme": "dusk"}"#)
    let store = SettingsStore(fileURL: file)
    #expect(store.reload() == ["autocomplete.height", "autocomplete.disable", "autocomplete.theme"])
    #expect(store.double("autocomplete.height") == 200)
    #expect(store.bool("autocomplete.disable") == true)
    #expect(store.string("autocomplete.theme") == "dusk")
  }

  @Test func reportsOnlyTheKeysThatChanged() throws {
    try write(#"{"a": 1, "b": "x", "c": true}"#)
    let store = SettingsStore(fileURL: file)
    store.reload()
    var notifications: [Set<String>] = []
    store.observe { _, changed in notifications.append(changed) }

    try write(#"{"a": 1, "b": "y", "d": null}"#)
    #expect(store.reload() == ["b", "c", "d"])
    #expect(store.reload().isEmpty)
    #expect(notifications == [["b", "c", "d"]])
  }

  @Test func keepsThePreviousValuesWhenTheFileIsBroken() throws {
    try write(#"{"a": 1}"#)
    let store = SettingsStore(fileURL: file)
    store.reload()
    try write(#"{"a": 2,"#)
    #expect(store.reload().isEmpty)
    #expect(store.double("a") == 1)
  }

  @Test func setWritesTheFileAndKeepsOutsideEdits() throws {
    try write(#"{"a": 1}"#)
    let store = SettingsStore(fileURL: file)
    store.reload()
    // Someone edits the file and the watcher has not caught up yet.
    try write(#"{"a": 1, "fromCLI": "yes"}"#)
    try store.set("autocomplete.width", .number(400))

    let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(saved == .object(["a": .number(1), "fromCLI": .string("yes"), "autocomplete.width": .number(400)]))
    #expect(store.values == saved.objectValue)
  }

  @Test func setWithNilOrNullRemovesTheKey() throws {
    let store = SettingsStore(fileURL: file)
    try store.set("x", .bool(true))
    try store.set("y", .string("keep"))
    var changes: [Set<String>] = []
    store.observe { _, changed in changes.append(changed) }
    try store.set("x", nil)
    try store.set("y", .null)
    #expect(store.values.isEmpty)
    #expect(changes == [["x"], ["y"]])
  }

  @Test func changedKeysCoversAddedRemovedAndModified() {
    let old: [String: JSONValue] = ["a": .number(1), "b": .bool(true)]
    let new: [String: JSONValue] = ["a": .number(2), "c": .null]
    #expect(SettingsStore.changedKeys(from: old, to: new) == ["a", "b", "c"])
    #expect(SettingsStore.changedKeys(from: old, to: old).isEmpty)
  }

  @Test func watcherPicksUpOutsideChanges() async throws {
    let store = SettingsStore(fileURL: file)
    store.reload()
    store.startWatching()
    defer { store.stopWatching() }
    // FSEvents needs a moment before a new stream reports anything.
    try await Task.sleep(for: .milliseconds(300))
    try write(#"{"autocomplete.theme": "moss"}"#)
    #expect(await eventually(timeout: .seconds(10)) { store.string("autocomplete.theme") == "moss" })
  }
}
