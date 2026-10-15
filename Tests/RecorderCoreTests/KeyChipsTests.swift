import Foundation
import Testing
@testable import RecorderCore

@Test func keyChipLabelOrdersModifiers() {
    let command: UInt = 0x100000
    let shift: UInt = 0x20000
    let control: UInt = 0x40000
    let option: UInt = 0x80000

    // No modifiers: just the key name.
    #expect(keyChipLabel(keyCode: 0x00, mods: 0) == "A") // kVK_ANSI_A

    // All four modifiers, in macOS order ⌃ ⌥ ⇧ ⌘, regardless of the order the bits are combined in.
    let allMods = command | shift | control | option
    #expect(keyChipLabel(keyCode: 0x28, mods: allMods) == "⌃ ⌥ ⇧ ⌘ K") // kVK_ANSI_K

    // Two modifiers still come out in the fixed order, not the order they were passed.
    #expect(keyChipLabel(keyCode: 0x28, mods: shift | command) == "⇧ ⌘ K")
    #expect(keyChipLabel(keyCode: 0x28, mods: command | shift) == "⇧ ⌘ K")

    // Named / arrow / function keys.
    #expect(keyChipLabel(keyCode: 0x24, mods: 0) == "↩")
    #expect(keyChipLabel(keyCode: 0x31, mods: command) == "⌘ Space")
    #expect(keyChipLabel(keyCode: 0x7E, mods: 0) == "↑")
    #expect(keyChipLabel(keyCode: 0x7A, mods: 0) == "F1")
    #expect(keyChipLabel(keyCode: 0x6F, mods: 0) == "F12")
}

@Test func activeKeyChipExpiresAfterHold() {
    let events = [
        InputEvent(t: 1.0, k: .key, keyCode: 0x00, mods: 0x100000), // ⌘A at t=1
        InputEvent(t: 1.5, k: .key, keyCode: 0x08, mods: 0),         // C at t=1.5
        InputEvent(t: 5.0, k: .move, x: 0.5, y: 0.5),                // non-key, must be ignored
    ]

    // Just after the second key: both are within the hold window, so they merge into one label (age = newest).
    let hit = activeKeyChip(events: events, atSource: 1.6, hold: 1.2)
    #expect(hit?.label == "⌘ A C")
    #expect(hit.map { abs($0.age - 0.1) < 1e-9 } == true)

    // Right at the edge of the hold window for the second key (age == hold): expired.
    #expect(activeKeyChip(events: events, atSource: 1.5 + 1.2, hold: 1.2) == nil)

    // Well before either key: nothing active yet.
    #expect(activeKeyChip(events: events, atSource: 0.5, hold: 1.2) == nil)

    // Between the two keys: only the first exists yet.
    let mid = activeKeyChip(events: events, atSource: 1.2, hold: 1.2)
    #expect(mid?.label == "⌘ A")

    // Order-independent: shuffling the events array gives the same result.
    let shuffled = [events[2], events[0], events[1]]
    let shuffledHit = activeKeyChip(events: shuffled, atSource: 1.6, hold: 1.2)
    #expect(shuffledHit?.label == hit?.label)
    #expect(shuffledHit.map { abs($0.age - (hit?.age ?? -1)) < 1e-9 } == true)
}

@Test func keyCategories() {
    let command: UInt = 0x100000, shift: UInt = 0x20000
    #expect(keyCategory(keyCode: 0x08, mods: command) == .shortcut)
    #expect(keyCategory(keyCode: 0x00, mods: 0) == .typing)
    #expect(keyCategory(keyCode: 0x00, mods: shift) == .typing)
    #expect(keyCategory(keyCode: 0x31, mods: 0) == .typing) // Space
    #expect(keyCategory(keyCode: 0x7B, mods: 0) == .navigation)
    #expect(keyCategory(keyCode: 0x33, mods: 0) == .navigation)
    #expect(keyCategory(keyCode: 0x73, mods: 0) == .navigation) // Home
    #expect(keyCategory(keyCode: 0x7A, mods: 0) == .navigation) // F1
    #expect(keyCategory(keyCode: 0x37, mods: command) == .modifier) // ⌘ press itself
    #expect(keyCategory(keyCode: 0x38, mods: shift) == .modifier)
}

@Test func keyChipMergesAndFilters() {
    let events = [
        InputEvent(t: 1.0, k: .key, keyCode: 0x08, mods: 0x100000, ch: "c"),
        InputEvent(t: 1.2, k: .key, keyCode: 0x09, mods: 0x100000, ch: "v"),
        InputEvent(t: 1.4, k: .key, keyCode: 0x04, mods: 0, ch: "h"),
        InputEvent(t: 1.5, k: .key, keyCode: 0x22, mods: 0, ch: "i"),
        InputEvent(t: 1.6, k: .key, keyCode: 0x7B, mods: 0),
    ]
    #expect(activeKeyChip(events: events, atSource: 1.7)?.label == "⌘ C ⌘ V hi ←")
    #expect(activeKeyChip(events: events, atSource: 1.7, categories: [.shortcut])?.label == "⌘ C ⌘ V")
    #expect(activeKeyChip(events: events, atSource: 1.7, categories: [.typing])?.label == "hi")
    #expect(activeKeyChip(events: events, atSource: 1.7, categories: [])  == nil)
    #expect(keyChipLabel(keyCode: 0x27, mods: 0) == "'")
}

@Test func keysLegacyAllKeysDecode() throws {
    #expect(try JSONDecoder().decode(Keys.self, from: Data(#"{"show":true,"allKeys":false}"#.utf8)).typing == false)
    #expect(try JSONDecoder().decode(Keys.self, from: Data(#"{"show":true,"allKeys":true}"#.utf8)).typing == true)
    let fresh = try JSONDecoder().decode(Keys.self, from: Data(#"{"show":true}"#.utf8))
    #expect(fresh.shortcuts && fresh.typing && fresh.navigation && fresh.modifiers)
}
