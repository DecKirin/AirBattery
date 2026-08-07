//
//  DeviceCapsuleGrid.swift
//  AirBattery
//
//  Liquid Glass device grid used by the transparent dropdown (status bar + Dock surfaces share it).
//  Layout constants here are also read by AirBatteryApp.swift to size the borderless window that
//  hosts this content, since it isn't auto-sized by a system container like NSPopover was.
//

import SwiftUI

// MARK: - Theme

/// User-selectable theme for the dropdown panel.
///
/// `adaptive` is the original behaviour and stays the default: the panel window carries no explicit
/// appearance, so the Liquid Glass samples whatever is behind it and the `.primary`/`.secondary`
/// content tracks that backdrop — which is why the capsules stay legible over both a dark and a
/// light wallpaper regardless of the macOS appearance setting. The other three pin an appearance on
/// the window, so the glass resolves light or dark no matter what it is floating over.
enum DropdownTheme: String, CaseIterable, Identifiable {
    case adaptive
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Falls back to `.adaptive` for an unset or unrecognised stored value.
    static func current() -> DropdownTheme {
        DropdownTheme(rawValue: ud.string(forKey: "dropdownTheme") ?? "") ?? .adaptive
    }

    var helpText: String {
        switch self {
        case .adaptive: "Follows the desktop behind the panel, so it stays readable on any wallpaper"
        case .system: "Follows the macOS appearance setting"
        case .light: "Always light"
        case .dark: "Always dark"
        }
    }

    /// `nil` means "inherit", which is exactly what lets the glass sample its backdrop.
    var nsAppearance: NSAppearance? {
        switch self {
        case .adaptive: nil
        case .system: NSAppearance(named: systemPrefersDark ? .darkAqua : .aqua)
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The scheme this theme pins to, or `nil` when adaptive.
    var pinnedScheme: ColorScheme? {
        switch self {
        case .adaptive: nil
        case .system: systemPrefersDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    private var systemPrefersDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Pinned-theme plumbing
//
// `NSAppearance` alone is not enough to pin the panel. Liquid Glass samples the desktop behind it
// and `.primary`/`.secondary` are *vibrancy* styles, so a moment after the window appears they
// re-resolve against that backdrop — the panel would flash the chosen theme and then drift back to
// tracking the wallpaper. Pinned modes fix the content inks with concrete colours (vibrancy leaves
// those alone) and tint the glass to bias its base tone.
//
// A pinned mode is therefore a *partial* pin, by choice. Fully fixing the tone means occluding the
// backdrop, and occluding the backdrop is precisely what flattens the capsule — an opaque base
// layer was tried and it read as a flat plate while still greying out over a dark wallpaper. Since
// the two goals are in direct tension, this keeps the glass intact and accepts that pinned modes
// still shift somewhat with the desktop. Adaptive remains the default and is unaffected.

private struct DropdownPinnedSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// Non-nil when the dropdown is pinned to a fixed light/dark theme.
    var dropdownPinnedScheme: ColorScheme? {
        get { self[DropdownPinnedSchemeKey.self] }
        set { self[DropdownPinnedSchemeKey.self] = newValue }
    }
}

/// Publishes the selected theme into the environment. Reads `@AppStorage` so the panel and the
/// Settings preview both follow the picker without any manual refresh.
struct DropdownThemeEnvironment: ViewModifier {
    @AppStorage("dropdownTheme") private var raw = DropdownTheme.adaptive.rawValue
    var override: DropdownTheme?

    init(override: DropdownTheme? = nil) { self.override = override }

    func body(content: Content) -> some View {
        let scheme = (override ?? DropdownTheme(rawValue: raw) ?? .adaptive).pinnedScheme
        content
            .environment(\.dropdownPinnedScheme, scheme)
            .modifier(ConditionalScheme(scheme: scheme))
    }
}

/// Applies `colorScheme` only when pinned, leaving it untouched in adaptive mode.
private struct ConditionalScheme: ViewModifier {
    var scheme: ColorScheme?
    func body(content: Content) -> some View {
        if let scheme { content.colorScheme(scheme) } else { content }
    }
}

/// Which ink a piece of dropdown content uses.
enum DropdownInk { case primary, secondary }

private struct DropdownForeground: ViewModifier {
    var ink: DropdownInk
    var opacity: Double
    @Environment(\.dropdownPinnedScheme) private var pinned

    func body(content: Content) -> some View {
        if let pinned {
            let base: Color = (pinned == .dark) ? .white : .black
            let level = (ink == .secondary) ? 0.6 : 1.0
            return AnyView(content.foregroundStyle(base.opacity(level * opacity)))
        }
        let style: AnyShapeStyle = (ink == .secondary) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
        return AnyView(content.foregroundStyle(style.opacity(opacity)))
    }
}

extension View {
    /// Vibrancy-safe foreground: hierarchical styles when adaptive, concrete colours when pinned.
    func dropdownForeground(_ ink: DropdownInk, opacity: Double = 1.0) -> some View {
        modifier(DropdownForeground(ink: ink, opacity: opacity))
    }
}

// MARK: - Layout constants (shared with AirBatteryApp.swift's window sizing)

let dropdownPanelWidth: CGFloat = 380
let dropdownOuterPadding: CGFloat = 20
let dropdownToolbarHeight: CGFloat = 44
let dropdownToolbarSpacing: CGFloat = 14
let dropdownGridSpacing: CGFloat = 18
let dropdownCapsuleHeight: CGFloat = 64
let dropdownCapsuleFillInset: CGFloat = 6
let dropdownBadgeHeight: CGFloat = 26
let dropdownBadgeOverlap: CGFloat = dropdownBadgeHeight / 2
let dropdownCapsuleCellHeight: CGFloat = dropdownCapsuleHeight + dropdownBadgeOverlap
let dropdownToolbarButtonSize: CGFloat = 44

/// Precomputed panel height for the borderless window, since it isn't auto-sized like `NSPopover` was.
func estimatedDropdownHeight(deviceCount: Int) -> CGFloat {
    let rows = max(1, Int(ceil(Double(max(deviceCount, 1)) / 2.0)))
    let gridHeight = CGFloat(rows) * dropdownCapsuleCellHeight + CGFloat(max(0, rows - 1)) * dropdownGridSpacing
    return dropdownOuterPadding * 2 + dropdownToolbarHeight + dropdownToolbarSpacing + gridHeight
}

// MARK: - Chrome (per-element Liquid Glass)
//
// There is deliberately no panel-wide backdrop: the window is fully transparent and each capsule,
// badge and toolbar button carries its own glass, so they float over the desktop.
//
// In ADAPTIVE mode the content is appearance-agnostic (`.primary`/`.secondary`, never hardcoded
// white) and the glass is applied *to the content view itself*, never stacked behind it as a
// sibling layer. That distinction is what makes those styles pick up vibrancy and track the
// backdrop; as a detached `.background { }` the glass adapted but its icons and text stayed locked
// to the system-appearance colour and went unreadable on dark wallpapers.
//
// In a PINNED mode that same vibrancy is the bug rather than the feature — it is what dragged the
// panel back to the wallpaper a second after it opened. Pinned modes keep the glass (its texture is
// the look) and instead use concrete colours via `dropdownForeground`, plus a tint that pins the
// glass's base tone. See the pinned-theme plumbing above.
/// Tint that pins the glass's base tone without giving up the glass.
///
/// Dropping to `.regularMaterial` for pinned themes did hold the theme, but it also threw away the
/// Liquid Glass texture — the refraction and specular edge are the whole look. Keeping
/// `glassEffect` and tinting it instead retains that texture while stopping the base tone from
/// reading as whatever happens to be behind the window. The content inks are pinned separately by
/// `dropdownForeground`, which is what actually stopped the drift.
private func pinnedGlassTint(_ scheme: ColorScheme?) -> Color? {
    switch scheme {
    case .dark: Color.black.opacity(0.42)
    case .light: Color.white.opacity(0.42)
    default: nil
    }
}

/// Neutral chrome behind the capsule track, the badge and the empty-state pill.
private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    @Environment(\.dropdownPinnedScheme) private var pinned

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if let tint = pinnedGlassTint(pinned) {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct ToolbarGlass: ViewModifier {
    @Environment(\.dropdownPinnedScheme) private var pinned

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if let tint = pinnedGlassTint(pinned) {
                content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
            } else {
                content.glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

extension View {
    /// Neutral Liquid Glass — the capsule "track" and the empty-state pill.
    func chromeGlassBackground<S: InsettableShape>(in shape: S) -> some View {
        modifier(ChromeGlass(shape: shape))
    }

    /// The capsule track, which wraps the juice and the device label.
    func capsuleGlassBackground() -> some View {
        chromeGlassBackground(in: Capsule(style: .continuous))
    }

    /// Round glass for the toolbar buttons. `.interactive()` gives the native Liquid Glass
    /// hover/press response, so no manual opacity swapping is needed.
    func toolbarGlassBackground() -> some View {
        modifier(ToolbarGlass())
    }
}

/// Tinted Liquid Glass in a battery-tier color — the capsule "juice".
/// The tint carries the colour; no opaque fill underneath, so the glass stays translucent and the
/// panel keeps showing through it. This one is already tinted by the battery tier, so it never
/// needed a pinned variant — it keeps its glass in every theme.
struct TieredGlass<S: InsettableShape>: View {
    var shape: S
    var color: Color
    var fallbackOpacity: Double = 0.55

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(color.opacity(0.55)), in: shape)
        } else {
            shape.fill(color.opacity(fallbackOpacity))
        }
    }
}

func tieredGlass<S: InsettableShape>(_ shape: S, color: Color, fallbackOpacity: Double = 0.55) -> some View {
    TieredGlass(shape: shape, color: color, fallbackOpacity: fallbackOpacity)
}

// MARK: - Toolbar buttons

/// Circular glass button used in the dropdown's floating toolbar (Settings, Quit/Close).
struct CircleGlassButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .dropdownForeground(.primary)
                .frame(width: dropdownToolbarButtonSize, height: dropdownToolbarButtonSize)
                .toolbarGlassBackground()
        }
        .buttonStyle(.plain)
    }
}

/// Circular battery-health gauge for the Mac's own battery, reusing the trim-circle gauge technique
/// already used for the Dock tile icon in `MultiBatteryView` (ContentView.swift).
struct BatteryHealthRing: View {
    var health: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, health))) / 100)
                    .stroke(Color(getHealthColor(health)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(health)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigitIfAvailable()
                    .dropdownForeground(.primary)
            }
            .padding(6)
            .frame(width: dropdownToolbarButtonSize, height: dropdownToolbarButtonSize)
            .toolbarGlassBackground()
        }
        .buttonStyle(.plain)
        .help("\("Battery Health".local): \(health)%")
    }
}

// MARK: - Device capsule

/// One device rendered as a Liquid Glass capsule: a fixed-width translucent "track", a colored
/// "fill" capsule proportional to battery level (reusing `getPowerColor`'s existing 3-tier logic)
/// carrying the name/model text, and a small icon+percent badge peeking over the top edge.
struct DeviceCapsuleView: View {
    var device: Device
    var isHovered: Bool
    var isAlerting: Bool
    var isPinned: Bool
    var onHoverChanged: (Bool) -> Void
    var onToggleAlert: () -> Void
    var onTogglePin: () -> Void
    var onCopyName: () -> Void
    var onHide: () -> Void

    private var isInternalBattery: Bool { device.deviceID == "@MacInternalBattery" }
    private var isStale: Bool { (Date().timeIntervalSince1970 - device.lastUpdate) / 60 > 10 }
    private var subtitleText: String {
        if isInternalBattery {
            let label = device.isCharging != 0 ? "Until Full:" : "Until Empty:"
            return "\(label.local) \(InternalBattery.status.timeLeft)"
        }
        // `deviceModel` is a raw model identifier for Apple mobile devices ("iPhone17,1"); show the
        // marketing name where we know it. Other producers put a friendly string in there already
        // (AirPods), and those pass through untouched.
        guard let model = device.deviceModel else { return device.deviceType }
        return displayModelName(model)
    }

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let level = max(0, min(100, device.batteryLevel))
            let innerWidth = totalWidth - dropdownCapsuleFillInset * 2
            let fillHeight = dropdownCapsuleHeight - dropdownCapsuleFillInset * 2
            // Floor the fill at its own height so a low battery renders as a proper round-ended
            // pill. Anything narrower than `fillHeight` makes `Capsule` clamp its corner radius and
            // draw a squashed vertical blob — that was the malformed red fill at 1%.
            let fillWidth: CGFloat = device.hasBattery
                ? min(innerWidth, max(fillHeight, innerWidth * CGFloat(level) / 100))
                : 0

            ZStack(alignment: .topLeading) {
                // The juice and the label live *inside* the glass rather than beside it, so the
                // glass acts as their background. That is what lets `.primary`/`.secondary` pick up
                // vibrancy and track the backdrop; as a detached sibling layer the glass adapted but
                // the text stayed a fixed system-appearance colour and went unreadable on dark walls.
                ZStack(alignment: .topLeading) {
                    if device.hasBattery {
                        juiceShape
                            .frame(width: fillWidth, height: fillHeight)
                            .offset(x: dropdownCapsuleFillInset, y: dropdownCapsuleFillInset)
                    }
                    textContent(totalWidth: totalWidth)
                }
                .frame(width: totalWidth, height: dropdownCapsuleHeight, alignment: .topLeading)
                .capsuleGlassBackground()
                .offset(y: dropdownBadgeOverlap)
                badge
            }
        }
        .frame(height: dropdownCapsuleCellHeight)
        .contentShape(Rectangle())
        .onHover { onHoverChanged($0) }
    }

    private var tierColor: Color { Color(getPowerColor(device)) }

    /// The "juice" fill — tinted Liquid Glass in the battery-tier color.
    private var juiceShape: some View {
        tieredGlass(Capsule(style: .continuous), color: tierColor)
    }

    /// Icon + percentage in a glass pill riding on the capsule's top edge.
    ///
    /// Uses `.regular` glass, not `.clear`. `.clear` looked more transparent but does not vend
    /// vibrancy to its content, so the pill rendered as a fixed dark lens with fixed-colour content
    /// no matter what was behind it. `.regular` is still translucent and adapts like the capsule
    /// track and toolbar buttons. As always the glass is applied to the content, not stacked behind
    /// it, so the icon and label inherit that vibrancy.
    private var badge: some View {
        HStack(spacing: 4) {
            Image(getDeviceIcon(device))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .dropdownForeground(.primary)
            if device.hasBattery {
                Text("\(device.batteryLevel)%")
                    .font(.system(size: 11, weight: .semibold))
                    .dropdownForeground(.primary)
                    .monospacedDigitIfAvailable()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: dropdownBadgeHeight)
        .chromeGlassBackground(in: Capsule(style: .continuous))
        .offset(x: 12)
    }

    @ViewBuilder
    private func textContent(totalWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text((isStale ? "⚠︎ " : "") + device.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .dropdownForeground(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isAlerting {
                    Image(systemName: "bell.fill").font(.system(size: 9)).dropdownForeground(.secondary)
                }
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).dropdownForeground(.secondary)
                }
            }
            if isHovered && device.hasBattery {
                HStack(spacing: 8) {
                    Button(action: onToggleAlert) {
                        Image(isAlerting ? "bell.circle.fill" : "bell.circle")
                            .resizable().scaledToFit().frame(width: 15, height: 15)
                    }.buttonStyle(.plain)
                    if !isInternalBattery {
                        Button(action: onTogglePin) {
                            Image(isPinned ? "pin.circle.fill" : "pin.circle")
                                .resizable().scaledToFit().frame(width: 15, height: 15)
                        }.buttonStyle(.plain)
                    }
                    if #available(macOS 14, *) {
                        Button(action: onCopyName) {
                            Image("list.clipboard.fill.circle")
                                .resizable().scaledToFit().frame(width: 15, height: 15)
                        }.buttonStyle(.plain)
                    }
                    if !isInternalBattery {
                        Button(action: onHide) {
                            Image("eye.slash.circle")
                                .resizable().scaledToFit().frame(width: 15, height: 15)
                        }.buttonStyle(.plain)
                    }
                }
                .dropdownForeground(.primary, opacity: 0.85)
            } else {
                Text(subtitleText)
                    .font(.system(size: 10, weight: .regular))
                    .dropdownForeground(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        // Inset past the capsule's round end so text starts on the straight part, and keep a real
        // gap at the trailing edge instead of running to the rim.
        .padding(.leading, dropdownCapsuleFillInset + 16)
        .padding(.trailing, dropdownCapsuleFillInset + 14)
        .frame(width: totalWidth, height: dropdownCapsuleHeight, alignment: .leading)
    }
}
