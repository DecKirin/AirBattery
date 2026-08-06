//
//  ModernPopoverChrome.swift
//  AirBattery
//
//  Shared SwiftUI helpers (symbol rendering, typography) for the dropdown surfaces.
//

import SwiftUI
import AppKit

/// Tighten multi-digit battery labels on newer macOS (`tracking`); no-op before macOS 13.
struct DigitTightening: ViewModifier {
    var amount: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 13, *) {
            content.tracking(amount)
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func hierarchicalSymbolRendering() -> some View {
        if #available(macOS 12, *) {
            self.symbolRenderingMode(.hierarchical)
        } else {
            self
        }
    }

    @ViewBuilder
    func monospacedDigitIfAvailable() -> some View {
        if #available(macOS 12, *) {
            self.monospacedDigit()
        } else {
            self
        }
    }
}

