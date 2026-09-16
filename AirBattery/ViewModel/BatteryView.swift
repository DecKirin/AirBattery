//
//  BatteryView.swift
//  AirBattery
//
//  Created by apple on 2024/2/23.
//

import SwiftUI
import Combine

struct BatteryView: View {
    var item: Device
    var body: some View {
        let m = NativeBattery.classic
        let width = m.levelWidth(item.batteryLevel)
        ZStack{
            ZStack(alignment: .leading) {
                NativeBatteryShell(metrics: m)
                Group{
                    Rectangle()
                        .fill(Color(getPowerColor(item)))
                        .frame(width: width, height: m.levelSize.height, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: m.levelCornerRadius, style: .continuous))
                }.offset(x: m.levelOffset)
            }
            //.frame(width: 25.5, height: 12, alignment: .leading)
            if item.deviceID == "@MacInternalBattery" {
                if item.acPowered {
                    Image("batt_" + ((item.isCharging != 0 || item.isCharged) ? "bolt" : "plug") + "_mask")
                        .blendMode(.destinationOut)
                        .offset(x:-1.5)
                    Image("batt_" + ((item.isCharging != 0 || item.isCharged) ? "bolt" : "plug"))
                        .offset(x:-1.5)
                        .foregroundColor(.blackWhite)
                }
            }else{
                if item.isCharging != 0 {
                    Image("batt_" + ((item.isCharging == 5) ? "plug" : "bolt") + "_mask")
                        .blendMode(.destinationOut)
                        .offset(x:-1.5)
                    Image("batt_" + ((item.isCharging == 5) ? "plug" : "bolt"))
                        .offset(x:-1.5)
                        .foregroundColor(.blackWhite)
                }
            }
        }.compositingGroup()
    }
}

/// 菜单栏那颗电池 —— 只管画, 不管刷新. 定时更新交给 `StatusBarIcon`,
/// 这样同一份视图既能挂在视图树上, 也能离屏渲染成状态栏要的 template image
struct mainBatteryView: View {
    var item: iBattery = InternalBattery.status
    /// 渲染成 template image 时置 true. template 只看 alpha, 墨色必须完全不透明 ——
    /// `.primary` 是 labelColor, 自带 85% alpha, 拿它当墨画出来整颗电池会淡一截
    var templateInk: Bool = false
    @AppStorage("intBattOnStatusBar") var intBattOnStatusBar = true
    @AppStorage("colorfulBattery") var colorfulBattery = false
    @AppStorage("iosBatteryStyle") var iosBatteryStyle = false
    @AppStorage("showBatteryPercent") var showBatteryPercent = true
    @AppStorage("internalLevel") var internalLevel = false
    @AppStorage("hideLevel") var hideLevel = 100

    private var showPercent: Bool { showBatteryPercent && !(item.batteryLevel > hideLevel) }
    /// 单色墨. template 渲染时要不透明的黑, 其余情况沿用 .primary
    private var ink: Color { templateInk ? .black : .primary }
    private var levelColor: Color {
        if colorfulBattery { return Color(getPowerColor(ib2ab(item))) }
        return item.batteryLevel <= 10 ? .red : ink
    }
    private var chargingIcon: String { (item.isCharging || item.isCharged) ? "bolt" : "plug" }
    /// 百分比写在电池外面, 只有 macOS 26 以前的系统样式是这么放的.
    /// 26 起系统把百分比挪进了电池里面, iOS 样式一直都在里面
    private var percentOutside: Bool {
        showPercent && !iosBatteryStyle && !NativeBattery.usesFilledLevel
    }

    var body: some View {
        HStack(alignment: .center, spacing:4){
            if item.hasBattery && intBattOnStatusBar {
                if percentOutside {
                    Text("\(item.batteryLevel)%")
                        .font(.caption2)
                        .monospacedDigitIfAvailable()
                        .foregroundColor(ink)
                }
                if iosBatteryStyle {
                    iosBattery
                } else if NativeBattery.usesFilledLevel {
                    filledBattery(.menuBar)
                } else {
                    outlinedBattery(.menuBar)
                }
            } else {
                Image(systemName: "bolt.square.fill")
                    .hierarchicalSymbolRendering()
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 16, height: 16)
            }
        }
    }

    /// iOS 样式: 用 battery.100percent 这张矢量图叠两层, 左边一层按电量着色, 右边一层压暗当作空槽;
    /// 开着百分比就把数字挖在电池里, 否则充电时画闪电
    @ViewBuilder private var iosBattery: some View {
        ZStack(alignment: .leading) {
            Image("battery.100percent")
                .resizable().scaledToFit()
                .frame(width: 27)
                .opacity(0.4)
                .mask (
                    HStack {
                        Spacer().frame(minWidth: 0)
                        Rectangle().frame(width: min(25, CGFloat(100 - item.batteryLevel) / 100 * 27))
                    }
                )
            Image("battery.100percent")
                .resizable().scaledToFit()
                .foregroundColor(colorfulBattery ? Color(getPowerColor(ib2ab(item)) + "2") : (item.batteryLevel <= 10 ? .red : ink))
                .frame(width: 27)
                .mask (
                    HStack {
                        Rectangle().frame(width: max(2, CGFloat(item.batteryLevel) / 100 * 27))
                        Spacer().frame(minWidth: 0)
                    }
                )
            if showPercent {
                if colorfulBattery {
                    BatteryLevelView(item: item)
                        .foregroundColor(.white)
                } else {
                    BatteryLevelView(item: item)
                        .foregroundColor(.white)
                        .blendMode(.destinationOut)
                }
            } else if item.acPowered {
                Image("batt_" + chargingIcon + "_mask")
                    .blendMode(.destinationOut)
                    .offset(x:6.5)
                Image("batt_" + chargingIcon)
                    .offset(x:6.5)
                    .foregroundColor(.blackWhite)
            }
        }.compositingGroup()
    }

    /// macOS 26+ 的系统样式: 整块主体按电量填满, 百分比/充电符号挖在填充上.
    ///
    /// 满电这一档是在 macOS 27.0 (26A428) 的真菜单栏上逐像素量出来的 —— 主体 23×12pt 整块填满,
    /// 没有内缩的电量条也没有露出来的描边; 显示百分比时数字和一个 3.5×5pt 的小闪电一起挖在填充里,
    /// 不显示百分比时改成那个 11×14pt 的大闪电 (自带挖洞, 上下会戳出主体一点).
    ///
    /// 电量没满时 (78% / 93% 充电中量的): 整块主体先铺一层 50% 的底, 电量段再 100% 不透明地
    /// 从左往右盖上去, 左边保留主体圆角、右边是直的 —— 没充到的那段是"淡淡的一整块", 不是"一圈细线".
    ///
    /// 数字和充电符号是**一路挖到底**的: 电量段和底都挖穿. 不用在没充到那段把它们再画回来 ——
    /// 底本来就是 50%, 挖出来的洞是 0%, 对比度够看. 早先那版在空白段把字画回去, 结果横跨电量
    /// 边界的闪电被拦腰截断, 只剩左半截 (实测宽度 2.6pt, 系统是 4.5pt).
    @ViewBuilder private func filledBattery(_ m: NativeBattery) -> some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                NativeBatteryTrack(metrics: m, ink: ink)
                NativeBatteryFill(metrics: m, level: item.batteryLevel, color: levelColor)
                if showPercent {
                    filledGlyphGroup(m).blendMode(.destinationOut)
                } else if item.acPowered {
                    // 26 起这里用的是大一号那套充电图标, 会上下各戳出主体一点点
                    NativeBatteryChargingGlyph(metrics: m, bolt: chargingIcon == "bolt", tint: ink, large: true)
                        .frame(width: m.bodySize.width, height: m.bodySize.height)
                }
            }
            .compositingGroup()
        }
    }

    /// 三位数 (100%) 且旁边带充电符号时整组缩一点. 系统也是这么干的: 同样是充电中, 两位数时数字 7.0pt、
    /// 闪电 4.5×7.0, 到了 100% 就变成 6.5pt / 3.5×5.0 —— 不缩的话 "100" 加闪电要占 21.9pt,
    /// 塞不进 23pt 的主体 (系统那组是 19.0pt, 19.0/21.9 ≈ 0.87).
    /// 没接电源时光是 "100" 有 23pt 塞得下, 系统就不缩 (真菜单栏上量: 100% 不充电的数字高度
    /// 和 95% 一样都是 8.0pt), 我们缩了反而比它小一圈
    private var glyphScale: CGFloat {
        item.batteryLevel > 99 && item.acPowered ? FilledBatteryGlyph.threeDigitScale : 1
    }

    /// 填充式电池里那组 "百分比 + 充电符号", 在主体里居中
    private func filledGlyphGroup(_ m: NativeBattery) -> some View {
        HStack(spacing: FilledBatteryGlyph.symbolSpacing) {
            // 用比例数字, 不用等宽: 系统的 "100" 里那个 1 就是窄的 —— 在真菜单栏上量, 等宽的 "100"
            // 比系统宽 1pt (35 vs 33px @2x), 换成比例数字后包围盒 (x 6..38) 和墨量都和系统一致
            Text("\(item.batteryLevel)")
                .font(.system(size: FilledBatteryGlyph.fontSize * glyphScale, weight: FilledBatteryGlyph.weight))
                .modifier(DigitTightening(amount: glyphScale < 1 ? FilledBatteryGlyph.tightening : 0))
            if item.acPowered { filledChargingSymbol(m) }
        }
        // 不加这个 SwiftUI 会拿下面那个 23pt 的 frame 去挤文字, 三位数直接被截成 "1…"
        .fixedSize()
        .frame(width: m.bodySize.width, height: m.bodySize.height)
    }

    /// 百分比右边那个充电符号. 直接拿系统那张 battery-bolt / battery-plug 缩小来用,
    /// 形状就不会走样 —— 之前用 SF Symbol 的 bolt.fill 凑, 大小和轮廓都对不上
    @ViewBuilder private func filledChargingSymbol(_ m: NativeBattery) -> some View {
        let h = FilledBatteryGlyph.symbolCanvasHeight * glyphScale
        if let glyph = m.artwork?.glyph(bolt: chargingIcon == "bolt") {
            Image(nsImage: glyph.image).renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: h * 11 / 14, height: h)
        } else {
            Image(systemName: chargingIcon == "bolt" ? "bolt.fill" : "powerplug.portrait.fill")
                .font(.system(size: FilledBatteryGlyph.symbolFallbackFontSize, weight: .medium))
        }
    }

    /// macOS 26 以前的系统样式: 空壳 + 内缩的电量条 + 充电图标. 外壳优先用系统自己那份图形
    @ViewBuilder private func outlinedBattery(_ m: NativeBattery) -> some View {
        let width = m.levelWidth(item.batteryLevel, minimum: 2)
        ZStack(alignment: .leading) {
            NativeBatteryShell(metrics: m, ink: ink)
            Rectangle()
                .fill(levelColor)
                .frame(width: width, height: m.levelSize.height, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: m.levelCornerRadius, style: .continuous))
                .offset(x: m.levelOffset)
            if item.acPowered {
                NativeBatteryChargingGlyph(metrics: m, bolt: chargingIcon == "bolt", tint: ink)
                    .frame(width: m.bodySize.width, height: m.bodySize.height)
            }
        }.compositingGroup()
    }
}

struct BatteryLevelView: View {
    var item: iBattery
    
    var body: some View {
        Group {
            if item.acPowered {
                HStack(spacing: -1) {
                    Text("\(item.batteryLevel)")
                        .font(item.batteryLevel > 99 ? .system(size: 10, weight: .medium) : .caption2.weight(.medium))
                        .monospacedDigitIfAvailable()
                        .modifier(DigitTightening(amount: item.batteryLevel > 99 ? -0.3 : 0))
                        .offset(y: item.batteryLevel > 99 ? 0.4 : 0.5)
                    Image(systemName: (item.isCharging || item.isCharged) ? "bolt.fill" : "powerplug.portrait.fill")
                        .hierarchicalSymbolRendering()
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 5)
                        .padding(.leading, 1)
                        .offset(y:item.batteryLevel < 100 ? 0.5 : 0)
                }
                .offset(x: item.batteryLevel < 100 ? 0.5 : -0.5)
                .offset(y: (item.acPowered && item.batteryLevel < 100) ? -0.5 : 0)
            } else {
                Text("\(item.batteryLevel)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigitIfAvailable()
            }
        }
        .frame(maxHeight: 12, alignment: .center)
        .frame(maxWidth: 24, alignment: .center)
    }
}

/// 菜单栏图标的刷新 + 渲染.
///
/// 以前是把 SwiftUI 视图当子视图塞进状态栏按钮里. 那样画出来的和系统自己的菜单栏图标对不上 ——
/// 系统图标走的是 **template image**: 交给 AppKit, 由它按菜单栏的材质去上色和混合, 深浅色、
/// 菜单展开时的反白也都归它管. 自己画的子视图这些全都没有, 实测比旁边系统图标亮一截.
///
/// 所以这里改成把视图离屏渲染成 template `NSImage` 再交给按钮, 剩下的让系统去画.
/// (「彩色电池」那个选项例外: template 只认 alpha, 上了就没颜色了, 那时候渲染成普通图片.)
/// 关于菜单栏里的横向占位, 留个记录:
///
/// 系统那颗电池的状态栏项量出来是 **42.0pt** (把 Control Center 的电池关掉, 它左边的项整体
/// 右移多少就是它的宽度 —— 两个参照项都给出 42.0), 墨迹 25.5pt.
/// 我们这项是 **41.5pt**, 差 0.5pt, 也就是 2x 屏上的一个物理像素.
///
/// 试过在左边补 0.5pt 把它顶到 42.0, 结果整项直接跳到 43.0 —— AppKit 给状态栏项算宽度时会
/// 自己取整, 不是我加多少就宽多少. 43.0 比 41.5 离 42.0 更远, 所以维持原样.
/// 再往下调只能补 0.25pt, 而那在 2x 屏上是半个物理像素, 会把整颗图标糊掉, 得不偿失.

@MainActor
final class StatusBarIcon {
    static let shared = StatusBarIcon()
    private var cancellables = Set<AnyCancellable>()
    /// 上一次画出来时的状态. 定时器每秒都响, 但状态没变就不用重画
    private var lastKey: String?

    private var colorful: Bool { ud.bool(forKey: "colorfulBattery") }

    /// 调试面板那几个开关会伪造一颗电池出来, 方便在没电池的机器上看效果
    private var currentBattery: iBattery {
        guard ud.bool(forKey: "test_debug") else { return getPowerState() }
        return iBattery(hasBattery: ud.bool(forKey: "test_hasib"),
                        isCharging: !ud.bool(forKey: "test_full"), isCharged: false,
                        acPowered: ud.bool(forKey: "test_acpower"), timeLeft: "",
                        batteryLevel: ud.integer(forKey: "test_iblevel"))
    }

    func start() {
        mainTimer.sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        dockTimer.sink { _ in refeshPinnedBar() }.store(in: &cancellables)
        // 设置里改了样式要马上看到, 不然得等下一次定时器
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    func refresh() {
        guard let button = statusBarItem?.button else { return }
        InternalBattery.status = currentBattery
        let item = InternalBattery.status
        let key = [
            "\(item.hasBattery)", "\(item.batteryLevel)", "\(item.isCharging)",
            "\(item.isCharged)", "\(item.acPowered)",
            "\(ud.bool(forKey: "intBattOnStatusBar"))", "\(ud.bool(forKey: "colorfulBattery"))",
            "\(ud.bool(forKey: "iosBatteryStyle"))", "\(ud.bool(forKey: "showBatteryPercent"))",
            "\(ud.integer(forKey: "hideLevel"))", "\(menuBarIsDark)",
            "\(statusBarItem?.button?.window?.backingScaleFactor ?? 0)"
        ].joined(separator: "|")
        // button.image 为空说明还没画过 (或者被清掉了), 那不管 key 一样不一样都要画
        guard key != lastKey || button.image == nil else { return }
        guard let image = render(item) else { return }
        lastKey = key
        button.image = image
    }

    /// 什么时候不能用 template: template 只保留 alpha, 颜色会全丢.
    /// 「彩色电池」和低电量变红都是靠颜色说话的, 这两种只能渲染成普通图片,
    /// 也就享受不到菜单栏的材质混合 —— 但它们本来就是要显眼, 不是要和系统图标一个色
    private func needsColor(_ item: iBattery) -> Bool {
        colorful || item.batteryLevel <= 10
    }

    /// 菜单栏是深是浅. 只有非 template 那条路要管 —— template 的颜色是 AppKit 给的,
    /// 但彩色电池/低电量那条是我们自己上色, ImageRenderer 默认按浅色环境解析,
    /// 不告诉它就会在深色菜单栏上画出一颗黑电池
    private var menuBarIsDark: Bool {
        statusBarItem?.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func render(_ item: iBattery) -> NSImage? {
        let template = !needsColor(item)
        let content = mainBatteryView(item: item, templateInk: template)
            .environment(\.colorScheme, menuBarIsDark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        // 按屏幕倍率的两倍出图. 系统那颗电池是矢量, 直接按设备分辨率栅格化;
        // 我们这边要过一遍位图, 正好卡在屏幕倍率上出的话, 充电图标周围那圈
        // 1.2pt 的缝会被抹薄一截 (实测 1.25pt → 1.00pt), 多给一倍余量就留得住
        let backing = statusBarItem?.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        renderer.scale = backing * 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = template
        return image
    }
}
