import Foundation
import Carbon.HIToolbox

/// A character's location on a US ANSI keyboard: which physical key position,
/// and whether Shift is required to produce it.
struct KeyStroke {
    let keyCode: CGKeyCode
    let shift: Bool
}

/// Remote-desktop clients in Scancode mode forward key *positions*, not characters,
/// and let the guest apply its own layout translation. So we can only type a
/// character if we know a physical key position that produces it under US ANSI --
/// which is what the Windows guest will assume it received.
///
/// The 47 printable positions of a US ANSI keyboard, unshifted and shifted.
/// Note the deliberately non-sequential number row (6 is 22, 5 is 23, 7 is 26,
/// 8 is 28): that is genuinely how macOS virtual key codes are laid out.
enum AnsiKeymap {

    private static let table: [(CGKeyCode, Character, Character)] = [
        (0,  "a", "A"), (1,  "s", "S"), (2,  "d", "D"), (3,  "f", "F"),
        (4,  "h", "H"), (5,  "g", "G"), (6,  "z", "Z"), (7,  "x", "X"),
        (8,  "c", "C"), (9,  "v", "V"), (11, "b", "B"), (12, "q", "Q"),
        (13, "w", "W"), (14, "e", "E"), (15, "r", "R"), (16, "y", "Y"),
        (17, "t", "T"), (31, "o", "O"), (32, "u", "U"), (34, "i", "I"),
        (35, "p", "P"), (37, "l", "L"), (38, "j", "J"), (40, "k", "K"),
        (45, "n", "N"), (46, "m", "M"),

        (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
        (23, "5", "%"), (22, "6", "^"), (26, "7", "&"), (28, "8", "*"),
        (25, "9", "("), (29, "0", ")"),

        (24, "=", "+"), (27, "-", "_"), (30, "]", "}"), (33, "[", "{"),
        (39, "'", "\""), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
        (44, "/", "?"), (47, ".", ">"), (50, "`", "~"),
    ]

    /// Printable ASCII -> key position. Space is handled separately (no shift pair).
    static let map: [Character: KeyStroke] = {
        var m: [Character: KeyStroke] = [:]
        for (code, plain, shifted) in table {
            m[plain] = KeyStroke(keyCode: code, shift: false)
            m[shifted] = KeyStroke(keyCode: code, shift: true)
        }
        m[" "] = KeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false)
        return m
    }()

    /// Characters that have no ANSI position but a faithful-enough ASCII stand-in.
    /// Dictation produces these constantly -- smart quotes especially, and a curly
    /// apostrophe silently turns "it's" into "its" if we just drop it.
    private static let transliterations: [Character: String] = [
        "\u{2018}": "'",  "\u{2019}": "'",           // curly single quotes
        "\u{201C}": "\"", "\u{201D}": "\"",          // curly double quotes
        "\u{2013}": "-",  "\u{2014}": "-",           // en dash, em dash
        "\u{2026}": "...",                            // ellipsis
        "\u{00A0}": " ",  "\u{2007}": " ",           // non-breaking spaces
        "\u{2009}": " ",  "\u{200A}": " ",           // thin spaces
        "\u{2022}": "-",                              // bullet
        "\u{00B7}": "-",                              // middle dot
        "\u{2032}": "'",  "\u{2033}": "\"",          // prime, double prime
    ]

    /// Flatten dictated text down to something typeable as US ANSI key positions.
    ///
    /// Newlines and tabs become spaces on purpose. Synthesizing a real Return into
    /// a remote session submits whatever form or chat box has focus, with no way to
    /// check first; Tab moves focus somewhere we can no longer see. Neither is worth
    /// the risk for dictated prose.
    ///
    /// Returns the typeable text and any characters that had to be dropped.
    static func sanitize(_ input: String) -> (text: String, dropped: [Character]) {
        var out = ""
        var dropped: [Character] = []

        for ch in input {
            if ch == "\n" || ch == "\r" || ch == "\t" {
                out.append(" ")
            } else if map[ch] != nil {
                out.append(ch)
            } else if let sub = transliterations[ch] {
                out.append(sub)
            } else {
                dropped.append(ch)
            }
        }

        // Collapse the runs of spaces that newline conversion tends to create.
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }

        return (out.trimmingCharacters(in: .whitespaces), dropped)
    }
}
