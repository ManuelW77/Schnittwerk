// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Lengths are stored in millimetres everywhere; the user sees and types
// them in millimetres or inches (Settings → General).

import SwiftUI

enum LengthUnit: String, CaseIterable, Identifiable {
    case mm, inch
    var id: String { rawValue }

    static let storageKey = "lengthUnit"

    static var current: LengthUnit {
        LengthUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .mm
    }

    var mmPerUnit: Double { self == .mm ? 1 : 25.4 }
    var symbol: String { self == .mm ? "mm" : "in" }

    var title: String {
        switch self {
        case .mm: String(localized: "Millimetres")
        case .inch: String(localized: "Inches")
        }
    }

    var format: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...(self == .mm ? 2 : 3)))
    }

    /// "12,5 mm" or "0,492 in".
    func text(_ mm: Double) -> String { (mm / mmPerUnit).formatted(format) + " " + symbol }
}

/// Text field for a length in mm, shown in the chosen unit.
struct LengthField: View {
    let title: LocalizedStringKey
    @Binding var mm: Double
    @AppStorage(LengthUnit.storageKey) private var unit: LengthUnit = .mm

    init(_ title: LocalizedStringKey, mm: Binding<Double>) {
        self.title = title
        _mm = mm
    }

    var body: some View {
        TextField(value: Binding(get: { mm / unit.mmPerUnit },
                                 set: { v in if v.isFinite { mm = v * unit.mmPerUnit } }),
                  format: unit.format) {
            Text(title) + Text(verbatim: " (\(unit.symbol))")
        }
    }
}
