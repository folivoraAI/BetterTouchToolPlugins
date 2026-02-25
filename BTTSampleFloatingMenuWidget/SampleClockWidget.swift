//
//  SampleClockWidget.swift
//  BTTSampleFloatingMenuWidget
//
//  Created by Andreas Hegenberg on 25.02.26.
//

import Foundation
import SwiftUI
import AppKit

@objc class SampleClockWidget: NSObject, BTTFloatingMenuWidgetInterface {
    weak var delegate: (any BTTFloatingMenuWidgetDelegate)?

    static func widgetName() -> String { "Clock Widget" }
    static func widgetDescription() -> String { "Shows current time" }
    static func widgetIcon() -> String { "clock.fill" }

    static func additionalActionCategories() -> [[String: Any]]? {
        return [
            [
                "CategoryActionName": "On Minute Change",
                "CategoryTag": NSNumber(value: 1000),
                "CategoryIconName": "clock.badge",
                "CategoryColor": NSColor.systemTeal
            ]
        ]
    }

    func makeWidgetView() -> NSView {
        return NSHostingView(rootView: ClockView())
    }

    func widgetDidAppear() {}
    func widgetWillDisappear() {}
}

struct ClockView: View {
    @State private var time = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(time, style: .time)
            .font(.system(size: 24, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(12)
            .onReceive(timer) { time = $0 }
    }
}
