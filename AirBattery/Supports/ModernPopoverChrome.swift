//
//  ModernPopoverChrome.swift
//  AirBattery
//
//  Shared SwiftUI helpers (symbol rendering, typography). Menu bar popover chrome comes from
//  NSPopover — do not stack glassEffect/material overlays on content or they paint above the list.
//

import SwiftUI
import AppKit

/// Continuous corner radius for row highlights (Wi‑Fi “Known Network” / settings list style).
private let menuPopoverRowHighlightCornerRadius: CGFloat = 12

/// Light gray ~ `#E5E5E5` for hover/selection in light appearance; subtle lift in dark.
private func menuPopoverRowHighlightFillColor(isActive: Bool) -> Color {
    guard isActive else { return .clear }
    if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        return Color.white.opacity(0.1)
    }
    return Color.gray.opacity(0.2)
}

/// Rounded hover / highlight pill matching Wi‑Fi settings–style list rows (large radius, solid light gray).
extension View {
    @ViewBuilder
    func menuPopoverRowHighlight(isActive: Bool, verticalInset: CGFloat = 5) -> some View {
        if #available(macOS 12, *) {
            self
                .padding(.vertical, verticalInset)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: menuPopoverRowHighlightCornerRadius, style: .continuous)
                        .fill(menuPopoverRowHighlightFillColor(isActive: isActive))
                }
                .contentShape(RoundedRectangle(cornerRadius: menuPopoverRowHighlightCornerRadius, style: .continuous))
                .padding(.horizontal, 9)
                .padding(.vertical, 0.5)
        } else {
            self
                .padding(.vertical, verticalInset)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: menuPopoverRowHighlightCornerRadius, style: .continuous)
                        .fill(menuPopoverRowHighlightFillColor(isActive: isActive))
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 0.5)
        }
    }
}

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

