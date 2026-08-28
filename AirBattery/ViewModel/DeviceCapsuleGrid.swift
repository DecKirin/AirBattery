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

// MARK: - Dial unit style

/// How the toolbar dials (power wattage, battery health) label their unit.
///
/// The dials print a bare number, so the unit has to come from somewhere. `watermark` is the
/// original behaviour and stays the default: the glyph sits *behind* the digits, washed out far
/// enough to read as a tint in the glass, which keeps the whole width free for the number itself
/// ("140" stays full size). `badge` moves it out to a small glass circle overlapping the dial's
/// bottom-right edge, which reads more explicitly at the cost of a little clutter. `hidden` drops
/// it entirely for anyone who already knows which dial is which.
enum DropdownUnitStyle: String, CaseIterable, Identifiable {
    case hidden
    case watermark
    case badge

    var id: String { rawValue }

    /// Falls back to `.watermark` — the pre-existing look — for an unset or unrecognised value.
    static func current() -> DropdownUnitStyle {
        DropdownUnitStyle(rawValue: ud.string(forKey: "dropdownUnitStyle") ?? "") ?? .watermark
    }

    var helpText: String {
        switch self {
        case .hidden: "Just the number, with no unit on the dial"
        case .watermark: "The unit sits behind the number as a faint watermark"
        case .badge: "The unit rides in a small circle on the dial's lower-right edge"
        }
    }
}

// MARK: - Panel size

/// Overall size of the dropdown panel.
///
/// One multiplier drives every metric below rather than each size carrying its own table of values,
/// so the panel keeps its proportions — Small is the same design at 85%, not a different layout.
/// `regular` is the original 380pt panel and stays the default.
enum DropdownPanelSize: String, CaseIterable, Identifiable {
    case small
    case regular
    case large

    var id: String { rawValue }

    /// Falls back to `.regular` — the pre-existing size — for an unset or unrecognised value.
    static func current() -> DropdownPanelSize {
        DropdownPanelSize(rawValue: ud.string(forKey: "dropdownPanelSize") ?? "") ?? .regular
    }

    /// The multiplier every dropdown metric is expressed in.
    var scale: CGFloat {
        switch self {
        case .small: 0.85   // 323pt wide, 54pt capsules
        case .regular: 1.0  // 380pt wide, 64pt capsules
        case .large: 1.18   // 448pt wide, 76pt capsules
        }
    }

    var helpText: String {
        switch self {
        case .small: "A compact panel that takes up less of the screen"
        case .regular: "The standard panel size"
        case .large: "A roomier panel, easier to read on a large display"
        }
    }
}

// MARK: - Pinned-theme plumbing
//
// `NSAppearance` alone is not enough to pin the panel. Liquid Glass samples the desktop behind the
// (fully transparent) window and `.primary`/`.secondary` are *vibrancy* styles, so a moment after
// the window appears they re-resolve against that backdrop — the panel would flash the chosen theme
// and then drift back to tracking the wallpaper.
//
// A pinned mode therefore cuts both paths to the backdrop. Content inks become concrete colours
// (vibrancy leaves those alone), including `Shape.stroke` styles, which do not inherit
// `foregroundStyle` and so need `dropdownStroke`. And the chrome swaps `glassEffect` — whose
// backdrop is the window's and cannot be redirected — for a hand-built glassmorphic pane. See
// `GlassmorphicPane`.
//
// Adaptive keeps both mechanisms and is unaffected.

private struct DropdownPinnedSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

private struct DropdownUnitStyleKey: EnvironmentKey {
    static let defaultValue: DropdownUnitStyle = .watermark
}

extension EnvironmentValues {
    /// Non-nil when the dropdown is pinned to a fixed light/dark theme.
    var dropdownPinnedScheme: ColorScheme? {
        get { self[DropdownPinnedSchemeKey.self] }
        set { self[DropdownPinnedSchemeKey.self] = newValue }
    }

    /// How the toolbar dials label their unit.
    var dropdownUnitStyle: DropdownUnitStyle {
        get { self[DropdownUnitStyleKey.self] }
        set { self[DropdownUnitStyleKey.self] = newValue }
    }
}

/// Publishes the dropdown's appearance settings into the environment. Reads `@AppStorage` so the
/// panel and the Settings previews both follow the pickers without any manual refresh; the
/// overrides let a preview show a setting the user is only hovering over, not one already stored.
struct DropdownThemeEnvironment: ViewModifier {
    @AppStorage("dropdownTheme") private var raw = DropdownTheme.adaptive.rawValue
    @AppStorage("dropdownUnitStyle") private var unitRaw = DropdownUnitStyle.watermark.rawValue
    var override: DropdownTheme?
    var unitOverride: DropdownUnitStyle?

    init(override: DropdownTheme? = nil, unitOverride: DropdownUnitStyle? = nil) {
        self.override = override
        self.unitOverride = unitOverride
    }

    func body(content: Content) -> some View {
        let scheme = (override ?? DropdownTheme(rawValue: raw) ?? .adaptive).pinnedScheme
        let unit = unitOverride ?? DropdownUnitStyle(rawValue: unitRaw) ?? .watermark
        content
            .environment(\.dropdownPinnedScheme, scheme)
            .environment(\.dropdownUnitStyle, unit)
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

/// Vibrancy-safe stroke style, on the same terms as `dropdownForeground`.
///
/// That modifier only covers `foregroundStyle`, but a `Shape.stroke` takes its own `ShapeStyle` and
/// does not inherit it — so the toolbar dials' `.primary` tracks kept re-resolving against the
/// backdrop after everything else had been pinned.
func dropdownStroke(_ pinned: ColorScheme?, opacity: Double) -> AnyShapeStyle {
    guard let pinned else { return AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(opacity)) }
    return AnyShapeStyle(((pinned == .dark) ? Color.white : Color.black).opacity(opacity))
}

// MARK: - Layout constants (shared with AirBatteryApp.swift's window sizing)

// Every value here is the `regular` measurement times the user's panel-size multiplier. They are
// computed rather than stored so the size preference is re-read at layout time: that is what lets
// the Settings previews resize the moment the picker changes, while the panel itself picks the new
// size up the next time it opens — the same contract the theme picker already advertises.

/// The multiplier every dropdown metric is expressed in, from the user's panel-size preference.
var dropdownScale: CGFloat { DropdownPanelSize.current().scale }

/// Scales a one-off measurement — a font size, an icon frame, a nudge — with the panel.
///
/// Geometry alone is not enough: full-size type in a Small capsule would crowd it, so the text and
/// icons have to travel with the box that holds them.
func dropdownScaled(_ base: CGFloat) -> CGFloat { base * dropdownScale }

var dropdownPanelWidth: CGFloat { 380 * dropdownScale }
var dropdownOuterPadding: CGFloat { 20 * dropdownScale }
var dropdownToolbarHeight: CGFloat { 44 * dropdownScale }
var dropdownToolbarSpacing: CGFloat { 14 * dropdownScale }
var dropdownGridSpacing: CGFloat { 18 * dropdownScale }
var dropdownCapsuleHeight: CGFloat { 64 * dropdownScale }
var dropdownCapsuleFillInset: CGFloat { 6 * dropdownScale }
var dropdownBadgeHeight: CGFloat { 26 * dropdownScale }
var dropdownBadgeOverlap: CGFloat { dropdownBadgeHeight / 2 }
var dropdownCapsuleCellHeight: CGFloat { dropdownCapsuleHeight + dropdownBadgeOverlap }
var dropdownToolbarButtonSize: CGFloat { 44 * dropdownScale }
/// Diameter of the `badge` unit marker. Sized so that, sitting in the dial's bottom-right corner,
/// its centre lands on the dial's own circumference — half on the glass, half off it.
var dropdownUnitBadgeSize: CGFloat { 18 * dropdownScale }

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
// panel back to the wallpaper a second after it opened. Pinned modes therefore give up `glassEffect`
// entirely and render as glassmorphism instead. See `GlassmorphicPane`.

/// The glassmorphism recipe used by the pinned themes: a blurred pane, a translucent wash that fixes
/// the tone, a highlight gathering along the top-left edge, and a shadow lifting it off the desktop.
///
/// Pinned themes cannot use `glassEffect`. Its backdrop is the *window's* backdrop, and nothing drawn
/// inside the window can occlude that — a fill was tried on both sides of the glass and neither
/// worked. In front of it, the fill veiled the glass into a flat plate while the glass underneath
/// went on sampling. Behind it, the fill only ever lands beneath the glass's own render, so the panel
/// lost its translucency *and* the glass on top still tracked whatever sat behind the window — other
/// apps' windows as much as the wallpaper. Apple exposes no way to redirect that backdrop, so
/// holding a theme means building the pane by hand.
///
/// Glassmorphism is the right idiom for that, and it pins better than a thicker material would. A
/// material still *averages* whatever is behind it, so buying tone from thickness alone costs
/// transparency fast; the `wash` is a fixed colour, so it holds the tone at far lower opacity. That
/// is what lets the blur underneath drop to `.thinMaterial` and keeps the pane see-through.
private struct GlassmorphicPane<S: InsettableShape>: View {
    var shape: S
    var scheme: ColorScheme
    /// Overrides the neutral wash — the capsule's juice passes its battery-tier colour here.
    var wash: Color?
    /// Off for panes nested inside another one, where a shadow would read as a seam rather than lift.
    var elevated: Bool = true

    init(shape: S, scheme: ColorScheme, wash: Color? = nil, elevated: Bool = true) {
        self.shape = shape
        self.scheme = scheme
        self.wash = wash
        self.elevated = elevated
    }

    private var isDark: Bool { scheme == .dark }

    /// The layer that actually holds the theme. Everything else here is texture.
    private var washColor: Color {
        wash ?? (isDark ? Color.black.opacity(0.34) : Color.white.opacity(0.42))
    }

    /// Light caught along the top-left edge and falling away — the frosted-pane border.
    private var border: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [.white.opacity(0.34), .white.opacity(0.10), .white.opacity(0.04)]
                : [.white.opacity(0.90), .white.opacity(0.45), .white.opacity(0.18)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Sheen falling off the top edge, standing in for the way glass gathers light there.
    ///
    /// Note if the tier palette is ever swapped for deeper colours: this is white, so it bleaches the
    /// wash toward the backdrop, and the deeper the colour the more is lost. At 0.30 over a 0.55 wash
    /// only 38% of a tier colour reaches the screen — enough for the bright palette this is tuned
    /// against, but it turned a trial `rgb(20, 110, 80)` into `rgb(158, 193, 181)`.
    private var sheen: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(isDark ? 0.10 : 0.30), .clear],
            startPoint: .top, endPoint: .center
        )
    }

    var body: some View {
        shape
            .fill(.thinMaterial)
            .overlay(shape.fill(washColor))
            .overlay(shape.fill(sheen))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            // The window sets `hasShadow = false` so AppKit cannot draw one rectangle around the
            // whole panel, which leaves each pane free to cast its own — the elevation that
            // separates glassmorphism from a flat translucent card.
            .shadow(color: .black.opacity(isDark ? 0.38 : 0.18),
                    radius: elevated ? 9 : 0, x: 0, y: elevated ? 4 : 0)
    }
}

/// Neutral chrome behind the capsule track, the badge and the empty-state pill.
private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    @Environment(\.dropdownPinnedScheme) private var pinned

    func body(content: Content) -> some View {
        if let pinned {
            // A detached background is right *here* and wrong in adaptive mode: pinned content
            // already carries concrete inks, and keeping it outside the material is what stops
            // vibrancy from re-resolving those inks against the backdrop.
            content.background(GlassmorphicPane(shape: shape, scheme: pinned))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct ToolbarGlass: ViewModifier {
    @Environment(\.dropdownPinnedScheme) private var pinned

    func body(content: Content) -> some View {
        if let pinned {
            content.background(GlassmorphicPane(shape: Circle(), scheme: pinned))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
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

    /// Round glass for the toolbar buttons. In adaptive mode `.interactive()` gives the native
    /// Liquid Glass hover/press response, so no manual opacity swapping is needed; a pinned theme
    /// has no `glassEffect` to ask for it and the buttons stay static.
    func toolbarGlassBackground() -> some View {
        modifier(ToolbarGlass())
    }
}

/// Tinted Liquid Glass in a battery-tier color — the capsule "juice".
///
/// ADAPTIVE keeps `glassEffect`: the tint carries the colour with no fill underneath, so the glass
/// stays translucent and the panel keeps showing through it.
///
/// PINNED gives it up for the same reason `GlassmorphicPane` does — the juice sits *inside* the
/// capsule track, so leaving it on `glassEffect` would hold the track's theme while the juice went on
/// sampling whatever was behind the window, straight through it. It becomes another glassmorphic
/// pane, with the tier colour as its wash instead of the neutral one, so the hue stays put while the
/// blur underneath keeps it translucent. No shadow: nested inside the track, one would read as a
/// seam rather than as lift.
struct TieredGlass<S: InsettableShape>: View {
    var shape: S
    var color: Color
    var fallbackOpacity: Double = 0.55
    @Environment(\.dropdownPinnedScheme) private var pinned

    var body: some View {
        if let pinned {
            GlassmorphicPane(shape: shape, scheme: pinned, wash: color.opacity(0.55), elevated: false)
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(color.opacity(0.55)), in: shape)
        } else {
            shape.fill(color.opacity(fallbackOpacity))
        }
    }
}

func tieredGlass<S: InsettableShape>(_ shape: S, color: Color, fallbackOpacity: Double = 0.55) -> some View {
    TieredGlass(shape: shape, color: color, fallbackOpacity: fallbackOpacity)
}

// MARK: - Dial unit markers
//
// Both toolbar dials print a bare number and get their unit from one of these, picked by
// `DropdownUnitStyle`. They are two separate pieces because the two styles live at different depths:
// the watermark belongs *inside* the dial's ZStack, underneath the digits, while the badge has to be
// layered on after the glass so it can overhang the dial's edge.

/// The unit as a washed-out glyph behind the number. Kept faint enough to read as a tint in the
/// glass rather than as a second glyph competing with the number sitting on top of it.
private struct DialUnitWatermark: View {
    var unit: String
    /// The dials pick this differently: an un-ringed dial has its whole inner circle free, a ringed
    /// one has to leave the outer band clear.
    var size: CGFloat
    @Environment(\.dropdownUnitStyle) private var style

    var body: some View {
        if style == .watermark {
            Text(unit)
                .font(.system(size: size, weight: .bold))
                .dropdownForeground(.primary, opacity: 0.09)
        }
    }
}

/// The unit in a second, smaller glass circle straddling the dial's lower-right edge — the same
/// layering idiom as the capsules' icon badge, and the reason it uses the neutral chrome glass
/// rather than the toolbar's interactive variant: it is a marker on the button, not a button.
private struct DialUnitBadge: ViewModifier {
    var unit: String
    @Environment(\.dropdownUnitStyle) private var style

    func body(content: Content) -> some View {
        if style == .badge {
            content.overlay(alignment: .bottomTrailing) {
                Text(unit)
                    .font(.system(size: dropdownScaled(10), weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .dropdownForeground(.primary)
                    .frame(width: dropdownUnitBadgeSize, height: dropdownUnitBadgeSize)
                    .chromeGlassBackground(in: Circle())
                    // Pushed just past the corner so the badge clears the dial's own rim instead of
                    // sitting tangent to it. The toolbar row has `dropdownOuterPadding` below it and
                    // `dropdownToolbarSpacing` between buttons, so the 2pt overhang has room.
                    .offset(x: dropdownScaled(2), y: dropdownScaled(2))
            }
        } else {
            content
        }
    }
}

extension View {
    /// Layers the `badge` unit marker onto a toolbar dial. Apply *after* the dial's glass, so the
    /// badge sits on top of it. A no-op in the other two styles.
    func dialUnitBadge(_ unit: String) -> some View {
        modifier(DialUnitBadge(unit: unit))
    }
}

// MARK: - Toolbar buttons

/// Circular glass button used in the dropdown's floating toolbar (Settings, Quit/Close).
struct CircleGlassButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: dropdownScaled(17), weight: .medium))
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
    @Environment(\.dropdownPinnedScheme) private var pinned

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(dropdownStroke(pinned, opacity: 0.18), style: StrokeStyle(lineWidth: dropdownScaled(3.5), lineCap: .round))
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, health))) / 100)
                    .stroke(Color(getHealthColor(health)), style: StrokeStyle(lineWidth: dropdownScaled(3.5), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Unit on the same terms as `PowerWattageRing`, so the two adjacent dials read as
                // one pair rather than two unrelated gauges.
                DialUnitWatermark(unit: "%", size: dropdownScaled(20))
                Text("\(health)")
                    .font(.system(size: dropdownScaled(13), weight: .semibold))
                    .monospacedDigitIfAvailable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .dropdownForeground(.primary)
            }
            .padding(dropdownScaled(6))
            .frame(width: dropdownToolbarButtonSize, height: dropdownToolbarButtonSize)
            .toolbarGlassBackground()
            .dialUnitBadge("%")
        }
        .buttonStyle(.plain)
        .help("\("Battery Health".local): \(health)%")
    }
}

/// Ceiling the charge ring scales against: 140W, the largest adapter Apple ships (16" MacBook Pro
/// MagSafe). A 65W contract therefore fills just under half the ring.
let maxAdapterWatts: Double = 140

/// Power gauge for the Mac's own battery, sharing `BatteryHealthRing`'s trim-circle construction.
///
/// Two distinct readings share one dial, because only one of them is meaningful at a time:
/// plugged in it shows the *adapter's negotiated wattage* against the 140W ceiling, and on battery
/// it shows what the machine is *drawing*. Discharge has no comparable ceiling to scale against, so
/// it draws no arc at all — an empty track next to a live number would read as "0%".
struct PowerWattageRing: View {
    /// Wattage to print in the middle.
    var watts: Double
    /// Ring fill fraction, or nil to omit the ring entirely.
    var progress: Double?
    var help: String
    var action: () -> Void
    @Environment(\.dropdownPinnedScheme) private var pinned

    /// Whole watts while plugged in (adapters are rated in whole numbers anyway); one decimal on
    /// battery, where the draw is small enough that rounding to 6 vs 7 loses real signal — but only
    /// below 10, so the text never outgrows the circle. The unit is carried by the marker that
    /// `DropdownUnitStyle` picks rather than by a suffix here.
    private var label: String {
        if progress != nil || watts >= 10 { return "\(Int(watts.rounded()))" }
        return String(format: "%.1f", watts)
    }

    /// Discharge draws no arc, so the whole inner circle is free and both the digits and the
    /// watermark behind them can run bigger; the charging ring needs that outer band left clear.
    private var labelSize: CGFloat { dropdownScaled(progress == nil ? 15 : 13) }
    private var watermarkSize: CGFloat { dropdownScaled(progress == nil ? 21 : 18) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let progress {
                    Circle()
                        .stroke(dropdownStroke(pinned, opacity: 0.18), style: StrokeStyle(lineWidth: dropdownScaled(3.5), lineCap: .round))
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                        .stroke(Color("my_green"), style: StrokeStyle(lineWidth: dropdownScaled(3.5), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // Unit as a marker rather than a suffix: it frees the whole width for the digits
                // (so "140" stays full size) while keeping the reading unambiguous.
                DialUnitWatermark(unit: "W", size: watermarkSize)
                Text(label)
                    .font(.system(size: labelSize, weight: .semibold))
                    .monospacedDigitIfAvailable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .dropdownForeground(.primary)
            }
            .padding(dropdownScaled(6))
            .frame(width: dropdownToolbarButtonSize, height: dropdownToolbarButtonSize)
            .toolbarGlassBackground()
            .dialUnitBadge("W")
        }
        .buttonStyle(.plain)
        .help(help)
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
    /// A Pencil's `deviceModel` is the raw USB product ID that SpringBoard logs ("332", "222"), not
    /// a model identifier — `displayModelName` can't name it and a bare number says nothing. What is
    /// actually worth knowing on that line is which iPad it was read through, which `getPencil`
    /// already stores as the parent.
    private var isPencilWithParent: Bool {
        ["ApplePencil", "Pencil"].contains(device.deviceType) && !device.parentName.isEmpty
    }
    private var subtitleText: String {
        if isPencilWithParent { return device.parentName }
        // `deviceModel` is a raw model identifier for Apple mobile devices ("iPhone17,1"); show the
        // marketing name where we know it. Other producers put a friendly string in there already
        // (AirPods), and those pass through untouched.
        guard let model = device.deviceModel else { return device.deviceType }
        return displayModelName(model)
    }

    /// Subtitle for this Mac's own battery.
    ///
    /// A bolt carries the "charging" meaning that the old "Until Full:" prefix spelled out, so the
    /// remaining time gets the whole line instead of being squeezed by a label. Discharging needs no
    /// marker at all — a bare duration in this position reads as time remaining — and at full the
    /// time is meaningless ("∞"), so it is replaced by the state itself.
    @ViewBuilder
    private var internalBatterySubtitle: some View {
        if device.isCharged {
            Text("\(Image(systemName: "bolt.fill")) \("Fully Charged".local)")
        } else if device.isCharging != 0 {
            Text("\(Image(systemName: "bolt.fill")) \(InternalBattery.status.timeLeft)")
        } else {
            Text(InternalBattery.status.timeLeft)
        }
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
        HStack(spacing: dropdownScaled(4)) {
            Image(getDeviceIcon(device))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: dropdownScaled(14), height: dropdownScaled(14))
                .dropdownForeground(.primary)
            if device.hasBattery {
                Text("\(device.batteryLevel)%")
                    .font(.system(size: dropdownScaled(11), weight: .semibold))
                    .dropdownForeground(.primary)
                    .monospacedDigitIfAvailable()
            }
        }
        .padding(.horizontal, dropdownScaled(10))
        .frame(height: dropdownBadgeHeight)
        .chromeGlassBackground(in: Capsule(style: .continuous))
        .offset(x: dropdownScaled(12))
    }

    @ViewBuilder
    private func textContent(totalWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: dropdownScaled(2)) {
            HStack(spacing: dropdownScaled(3)) {
                Text((isStale ? "⚠︎ " : "") + device.deviceName)
                    .font(.system(size: dropdownScaled(12), weight: .semibold))
                    .dropdownForeground(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isAlerting {
                    Image(systemName: "bell.fill").font(.system(size: dropdownScaled(9))).dropdownForeground(.secondary)
                }
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: dropdownScaled(9))).dropdownForeground(.secondary)
                }
            }
            if isHovered && device.hasBattery {
                HStack(spacing: dropdownScaled(8)) {
                    Button(action: onToggleAlert) {
                        Image(isAlerting ? "bell.circle.fill" : "bell.circle")
                            .resizable().scaledToFit().frame(width: dropdownScaled(15), height: dropdownScaled(15))
                    }.buttonStyle(.plain)
                    if !isInternalBattery {
                        Button(action: onTogglePin) {
                            Image(isPinned ? "pin.circle.fill" : "pin.circle")
                                .resizable().scaledToFit().frame(width: dropdownScaled(15), height: dropdownScaled(15))
                        }.buttonStyle(.plain)
                    }
                    if #available(macOS 14, *) {
                        Button(action: onCopyName) {
                            Image("list.clipboard.fill.circle")
                                .resizable().scaledToFit().frame(width: dropdownScaled(15), height: dropdownScaled(15))
                        }.buttonStyle(.plain)
                    }
                    if !isInternalBattery {
                        Button(action: onHide) {
                            Image("eye.slash.circle")
                                .resizable().scaledToFit().frame(width: dropdownScaled(15), height: dropdownScaled(15))
                        }.buttonStyle(.plain)
                    }
                }
                .dropdownForeground(.primary, opacity: 0.85)
            } else {
                Group {
                    if isInternalBattery { internalBatterySubtitle } else { Text(subtitleText) }
                }
                    .font(.system(size: dropdownScaled(10), weight: .regular))
                    .dropdownForeground(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        // Inset past the capsule's round end so text starts on the straight part, and keep a real
        // gap at the trailing edge instead of running to the rim.
        .padding(.leading, dropdownCapsuleFillInset + dropdownScaled(16))
        .padding(.trailing, dropdownCapsuleFillInset + dropdownScaled(14))
        .frame(width: totalWidth, height: dropdownCapsuleHeight, alignment: .leading)
    }
}
