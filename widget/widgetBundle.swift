//
//  widgetBundle.swift
//  widget
//
//  Created by apple on 2024/2/18.
//

import WidgetKit
import SwiftUI

/// macOS 26 (Tahoe) / iOS 26 draw the widget container itself in Liquid Glass.
/// 只有当小组件不自己画不透明背景时, 系统的玻璃材质才会透出来.
let liquidGlassWidget: Bool = {
    if #available(macOS 26.0, *) { return true }
    return false
}()

/// 圆环底槽 / 占位符的灰度. Liquid Glass 背景是半透明的, 0.15 会被吃掉, 需要加重.
let trackOpacity: Double = liquidGlassWidget ? 0.28 : 0.15

extension View {
    func widgetBackground(_ backgroundView: some View) -> some View {
        if #available(macOS 14.0, *) {
            return containerBackground(for: .widget) {
                // 26 以上交给系统的 Liquid Glass, 自己画不透明背景会把玻璃盖住.
                if liquidGlassWidget { Color.clear } else { backgroundView }
            }
        } else {
            return background(backgroundView)
        }
    }
}

extension WidgetConfiguration {
    func disableContentMarginsIfNeeded() -> some WidgetConfiguration {
        if #available(macOS 12.0, *) {
            return self.contentMarginsDisabled()
        } else {
            return self
        }
    }
    
    func supportFamily() -> some WidgetConfiguration {
        if #available(macOS 14, *) {
            return self.supportedFamilies([.systemLarge, .systemMedium])
        } else {
            return self.supportedFamilies([.systemLarge, .systemMedium, .systemSmall])
        }
    }
}

@main
struct widgetBundle: WidgetBundle {
    var body: some Widget {
        widgets()
    }
    
    func widgets() -> some Widget {
        if #available(macOS 14, *) {
            return WidgetBundleBuilder.buildBlock(batteryWidget(), batteryWidget2New(), batteryWidget2(), batteryWidget3())
        } else {
            return WidgetBundleBuilder.buildBlock(batteryWidget(), batteryWidget2(), batteryWidget3())
        }
    }
}
