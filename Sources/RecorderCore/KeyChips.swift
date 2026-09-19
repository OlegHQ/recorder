import Foundation

/// SPEC §6.6 Keys tab, §4.8 key events: pure text/lookup for the keyboard-shortcut overlay chip
/// (rendering the chip to a Core-Text texture is the app-side, non-core part of T-602).
///
/// `mods` are raw `CGEventFlags` bits, as stored on `InputEvent.mods`: command = 0x100000,
/// shift = 0x20000, control = 0x40000, option = 0x80000.
private let commandFlag: UInt = 0x100000
private let shiftFlag: UInt = 0x20000
private let controlFlag: UInt = 0x40000
private let optionFlag: UInt = 0x80000

/// ANSI virtual keycodes (US layout, `Carbon.HIToolbox`'s `kVK_*` constants) for the keys the
/// overlay needs a name for: letters, digits, and the named/arrow/function keys.
private let keyNames: [Int: String] = [
    0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
    0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
    0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
    0x2D: "N", 0x2E: "M",
    0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x19: "9", 0x1A: "7",
    0x1C: "8", 0x1D: "0",

    0x29: ";", 0x27: "′", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x2A: "\\",
    0x21: "[", 0x1E: "]", 0x1B: "-", 0x18: "=", 0x32: "`",
    0x38: "Shift", 0x3C: "Shift", 0x37: "Command", 0x36: "Command",
    0x3B: "Control", 0x3E: "Control", 0x3A: "Option", 0x3D: "Option", 0x39: "Caps Lock",
    0x3F: "Fn", 0x4C: "⌤", 0x75: "⌦", 0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
    0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7", 0x5B: "8", 0x5C: "9",
    0x41: ".", 0x43: "*", 0x45: "+", 0x47: "Clear", 0x4B: "/", 0x4E: "-", 0x51: "=",
    0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    0x24: "↩", // Return
    0x30: "⇥",  // Tab
    0x33: "⌫", // Delete/Backspace
    0x35: "⎋", // Escape
    0x31: "Space",
    0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",

    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
    0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
]

/// The chip text for a key event: macOS modifier order `⌃ ⌥ ⇧ ⌘`, then the key name.
public func keyChipLabel(keyCode: Int, mods: UInt) -> String {
    var parts: [String] = []
    if mods & controlFlag != 0 { parts.append("⌃") }
    if mods & optionFlag != 0 { parts.append("⌥") }
    if mods & shiftFlag != 0 { parts.append("⇧") }
    if mods & commandFlag != 0 { parts.append("⌘") }
    parts.append(keyNames[keyCode] ?? "Key \(keyCode)")
    return parts.joined(separator: " ")
}

/// The most recent `.key` event within `hold` seconds before `t`, as a chip label + its age
/// (seconds since that key was pressed). `nil` once it has aged out. Pure and order-independent:
/// the result only depends on event timestamps, not on `events`' array order.
public func activeKeyChip(events: [InputEvent], atSource t: Double, hold: Double = 1.2, allKeys: Bool = true) -> (label: String, age: Double)? {
    let candidates = events.filter { $0.k == .key && $0.t <= t && t - $0.t < hold && (allKeys || isShortcutKey(code: $0.keyCode ?? -1, mods: $0.mods ?? 0)) }
    guard let latest = candidates.max(by: { $0.t < $1.t }) else { return nil }
    return (keyChipLabel(keyCode: latest.keyCode ?? 0, mods: latest.mods ?? 0), t - latest.t)
}

public func isShortcutKey(code: Int, mods: UInt) -> Bool {
    mods & (commandFlag | controlFlag | optionFlag) != 0 ||
    [36, 48, 51, 53, 76, 123, 124, 125, 126, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(code)
}
