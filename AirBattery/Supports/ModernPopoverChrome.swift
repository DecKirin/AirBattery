//
//  ModernPopoverChrome.swift
//  AirBattery
//
//  Shared SwiftUI helpers (symbol rendering, typography). Menu bar popover chrome comes from
//  NSPopover — do not stack glassEffect/material overlays on content or they paint above the list.
//

import SwiftUI
import AppKit

/// Hover pill transparency. **macOS 12+:** `1.0` matches system; lower = more see-through (e.g. `0.65`).
private let menuPopoverHighlightFillOpacity: Double = 0.65

/// **macOS 11** fallback uses `blackWhite` × this alpha when the row is hovered.
private let menuPopoverHighlightLegacyAlpha: Double = 0.15

/// Rounded hover / highlight pill matching system menu list rows (e.g. Bluetooth popover).
extension View {
    @ViewBuilder
    func menuPopoverRowHighlight(isActive: Bool, verticalInset: CGFloat = 5) -> some View {
        if #available(macOS 12, *) {
            self
                .padding(.vertical, verticalInset)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                .opacity(menuPopoverHighlightFillOpacity))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.horizontal, 9)
                .padding(.vertical, 0.5)
        } else {
            self
                .padding(.vertical, verticalInset)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.blackWhite.opacity(menuPopoverHighlightLegacyAlpha) : Color.clear)
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

