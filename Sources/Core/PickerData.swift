import Foundation

struct Pick {
    let value: String
    let name: String  // English Unicode name, used for search
}

enum PickerData {
    static func entries(for tab: PanelTab) -> [Pick] {
        switch tab {
        case .emoji: return emoji
        case .kaomoji: return kaomoji
        case .symbols: return symbols
        case .clipboard: return []
        }
    }

    // Built from Unicode properties instead of a hardcoded table: faces first, then people,
    // nature, food, travel, objects and symbols
    static let emoji: [Pick] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1FA70...0x1FAFF,
            0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x2600...0x27BF,
        ]
        var result: [Pick] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let props = scalar.properties
                guard props.isEmoji, !props.isEmojiModifier else { continue }
                // Text-style symbols need the emoji variation selector to render in color
                let string = props.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                result.append(Pick(value: string, name: props.name?.lowercased() ?? ""))
            }
        }
        return result
    }()

    static let kaomoji: [Pick] = [
        "(◕‿◕)", "(｡◕‿◕｡)", "(✿◠‿◠)", "ヽ(•‿•)ノ", "(＾▽＾)", "(*^‿^*)", "(≧◡≦)", "(ᵔᴥᵔ)",
        "ʕ•ᴥ•ʔ", "(=^･ω･^=)", "(づ｡◕‿‿◕｡)づ", "(っ˘ω˘ς)", "(♥ω♥*)", "(´｡• ᵕ •｡`)", "(✧ω✧)", "(*≧ω≦*)",
        "(o^▽^o)", #"\(^o^)/"#, "(ノ°▽°)ノ", "ヾ(⌐■_■)ノ♪", "(～￣▽￣)～", "(^人^)", "(○´∀`○)", "( ˘▽˘)っ♨",
        "(¬‿¬)", "(¬_¬)", "(ಠ_ಠ)", "(⊙_⊙)", "(°ロ°)", "(•_•)", "( •_•)>⌐■-■", "(⌐■_■)",
        "(T_T)", "(╥﹏╥)", "(ಥ﹏ಥ)", "(>_<)", "(；一_一)", "(ー_ー)zzz", "(￣^￣)", "(╬ಠ益ಠ)",
        "(╯°□°)╯︵ ┻━┻", "┬─┬ノ( º _ ºノ)", #"¯\_(ツ)_/¯"#, "ᕦ(ò_óˇ)ᕤ", "(ง •̀_•́)ง", "m(_ _)m", "＼(〇_ｏ)／", "(￣ε￣＠)",
    ].map { Pick(value: $0, name: "") }

    static let symbols: [Pick] = {
        let groups = [
            "«»„“”‘’—–…•·°′″№§¶©®™†‡‰",
            "€£¥₽₴₸₿¢$₩₹₺",
            "±×÷≠≈≡≤≥∞√∑∏∫∂∆∇∈∉∩∪⊂⊃∧∨¬∀∃∅∝∠⊥½⅓⅔¼¾⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃",
            "←↑→↓↔↕⇐⇑⇒⇓⇔↩↪↗↘↙↖",
            "αβγδεζηθικλμνξοπρστυφχψωΓΔΘΛΞΠΣΦΨΩ",
            "★☆✓✔✗✘■□▪▫●○◆◇▲△▼▽♠♣♥♦♪♫☀☁☂☎✉✈⌘⌥⇧⌃⎋⏎⌫",
            "àáâãäåæçèéêëìíîïñòóôõöøœùúûüýÿßÀÁÉÈÑÓÖÜ",
        ]
        return groups.joined().map { ch in
            Pick(value: String(ch), name: ch.unicodeScalars.first?.properties.name?.lowercased() ?? "")
        }
    }()
}
