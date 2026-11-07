// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Silhouette plotters that understand the same commands as the Cameo 4
// ("Cameo 4 line"). USB ids and widths were taken from the open-source
// project inkscape-silhouette (silhouette/Graphtec.py); only the Cameo 4
// itself was tested with Schnittwerk.

import Foundation

struct PlotterModel: Equatable, Hashable, Sendable {
    let name: String
    let vendorID: UInt16
    let productID: UInt16
    /// Widest cut the machine can do, in mm.
    let widthMM: Double
    /// Two tool holders (tool select command `J`).
    let twoTools: Bool
    /// Bluetooth with the Cameo 4 protocol.
    let bluetooth: Bool

    static let silhouetteVendor: UInt16 = 0x0B4D
    /// The Cameo 5 Alpha models use their own vendor id.
    static let alphaVendor: UInt16 = 0x3844

    static let cameo4 = PlotterModel(name: "Cameo 4", vendorID: silhouetteVendor, productID: 0x1137,
                                     widthMM: 304.8, twoTools: true, bluetooth: true)

    static let all: [PlotterModel] = [
        cameo4,
        PlotterModel(name: "Cameo 4 Plus", vendorID: silhouetteVendor, productID: 0x1138,
                     widthMM: 372, twoTools: true, bluetooth: true),
        PlotterModel(name: "Cameo 4 Pro", vendorID: silhouetteVendor, productID: 0x1139,
                     widthMM: 600, twoTools: true, bluetooth: true),
        PlotterModel(name: "Cameo 5", vendorID: silhouetteVendor, productID: 0x1140,
                     widthMM: 330.2, twoTools: true, bluetooth: false),
        PlotterModel(name: "Cameo 5 Plus", vendorID: silhouetteVendor, productID: 0x1141,
                     widthMM: 372, twoTools: true, bluetooth: false),
        PlotterModel(name: "Cameo 5 Alpha", vendorID: alphaVendor, productID: 0x0001,
                     widthMM: 330.2, twoTools: true, bluetooth: false),
        PlotterModel(name: "Cameo 5 Alpha Plus", vendorID: alphaVendor, productID: 0x0002,
                     widthMM: 372, twoTools: true, bluetooth: false),
        PlotterModel(name: "Cameo Pro MK-II", vendorID: silhouetteVendor, productID: 0x1146,
                     widthMM: 609, twoTools: true, bluetooth: false),
        PlotterModel(name: "Portrait 3", vendorID: silhouetteVendor, productID: 0x113A,
                     widthMM: 203, twoTools: false, bluetooth: false),
        PlotterModel(name: "Portrait 4", vendorID: silhouetteVendor, productID: 0x113F,
                     widthMM: 216, twoTools: false, bluetooth: false),
    ]

    static func usb(vendor: UInt16, product: UInt16) -> PlotterModel? {
        all.first { $0.vendorID == vendor && $0.productID == product }
    }

    /// Model from the name a plotter shows over Bluetooth, e.g. "CAMEO 4 PLUS".
    static func bluetooth(name: String) -> PlotterModel {
        let n = name.lowercased()
        let candidates = all.filter(\.bluetooth)
        if n.contains("pro"), let m = candidates.first(where: { $0.name.hasSuffix("Pro") }) { return m }
        if n.contains("plus"), let m = candidates.first(where: { $0.name.hasSuffix("Plus") }) { return m }
        return cameo4
    }

    /// Names for help texts, e.g. "Cameo 4, Cameo 4 Plus, …".
    static var supportedNames: String { all.map(\.name).joined(separator: ", ") }
}
