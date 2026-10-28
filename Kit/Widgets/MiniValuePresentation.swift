//
//  MiniValuePresentation.swift
//  Kit
//
//  Copyright © 2026 Max Yu. All rights reserved.
//

import Foundation

/// The value-dependent pixels in a Mini widget, excluding static labels and units.
internal struct MiniValuePresentation: Equatable {
    let number: Int?
    let colorZone: Int?

    init(value: Double, utilizationColor: Bool, orange: Double, red: Double) {
        let rounded = (value * 100).rounded() / 100
        self.number = Int(exactly: (rounded * 100).rounded(.towardZero))
        if !utilizationColor {
            self.colorZone = nil
        } else if value >= 0 && value <= orange {
            self.colorZone = 0
        } else if value >= orange && value <= red {
            self.colorZone = 1
        } else {
            self.colorZone = 2
        }
    }

    var text: String { self.number.map(String.init) ?? "–" }
}
