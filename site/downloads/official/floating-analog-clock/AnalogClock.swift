// BTT-Plugin-Name: Analog Clock
// BTT-Plugin-Identifier: com.folivora.btt.floating.analogclock
// BTT-Plugin-Type: FloatingMenuWidget
// BTT-Plugin-Icon: clock.fill

import Cocoa
import CoreGraphics

// Disambiguate cos/sin when compiled with -import-objc-header
@inline(__always) private func _cos(_ x: CGFloat) -> CGFloat { CoreGraphics.cos(x) }
@inline(__always) private func _sin(_ x: CGFloat) -> CGFloat { CoreGraphics.sin(x) }

class AnalogClock: NSObject, BTTFloatingMenuWidgetInterface {
    weak var delegate: (any BTTFloatingMenuWidgetDelegate)?

    private var clockView: AnalogClockView?

    static func widgetName() -> String { "Analog Clock" }
    static func widgetDescription() -> String { "A smooth analog clock with second hand" }
    static func widgetIcon() -> String { "clock.fill" }

    func makeWidgetView() -> NSView {
        let view = AnalogClockView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        self.clockView = view
        view.startTimer()
        return view
    }

    func widgetDidAppear() {
        clockView?.startTimer()
    }

    func widgetWillDisappear() {
        clockView?.stopTimer()
    }
}

// MARK: - Clock Drawing View

class AnalogClockView: NSView {

    private var timer: Timer?

    override var isFlipped: Bool { true }

    func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stopTimer()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let size = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = size * 0.45
        let bezelRadius = size * 0.48

        // --- Background ---
        ctx.saveGState()
        let bgGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0),
                CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.addEllipse(in: CGRect(x: center.x - bezelRadius, y: center.y - bezelRadius,
                                   width: bezelRadius * 2, height: bezelRadius * 2))
        ctx.clip()
        ctx.drawRadialGradient(bgGradient,
                               startCenter: CGPoint(x: center.x, y: center.y - radius * 0.3),
                               startRadius: 0,
                               endCenter: center, endRadius: bezelRadius,
                               options: [])
        ctx.restoreGState()

        // --- Bezel ring ---
        ctx.setStrokeColor(CGColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 1.0))
        ctx.setLineWidth(size * 0.02)
        ctx.addEllipse(in: CGRect(x: center.x - bezelRadius, y: center.y - bezelRadius,
                                   width: bezelRadius * 2, height: bezelRadius * 2))
        ctx.strokePath()

        // --- Tick marks ---
        for i in 0..<60 {
            let angle = CGFloat(i) * (.pi * 2.0 / 60.0) - .pi / 2.0
            let isHour = i % 5 == 0

            let outerR = radius * 0.92
            let innerR = isHour ? radius * 0.75 : radius * 0.85
            let lineWidth: CGFloat = isHour ? size * 0.02 : size * 0.006

            let outer = CGPoint(x: center.x + _cos(angle) * outerR,
                                y: center.y + _sin(angle) * outerR)
            let inner = CGPoint(x: center.x + _cos(angle) * innerR,
                                y: center.y + _sin(angle) * innerR)

            ctx.setStrokeColor(isHour
                ? CGColor(red: 0.9, green: 0.88, blue: 0.82, alpha: 1.0)
                : CGColor(red: 0.5, green: 0.5, blue: 0.52, alpha: 1.0))
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: outer)
            ctx.addLine(to: inner)
            ctx.strokePath()
        }

        // --- Hour numerals ---
        let numeralFont = NSFont.systemFont(ofSize: size * 0.09, weight: .medium)
        let numeralColor = NSColor(calibratedRed: 0.85, green: 0.83, blue: 0.78, alpha: 1.0)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numeralFont,
            .foregroundColor: numeralColor,
            .paragraphStyle: paragraphStyle
        ]
        for hour in 1...12 {
            let angle = CGFloat(hour) * (.pi * 2.0 / 12.0) - .pi / 2.0
            let numeralR = radius * 0.63
            let pos = CGPoint(x: center.x + _cos(angle) * numeralR,
                              y: center.y + _sin(angle) * numeralR)
            let str = "\(hour)" as NSString
            let strSize = str.size(withAttributes: attrs)
            str.draw(in: CGRect(x: pos.x - strSize.width / 2,
                                y: pos.y - strSize.height / 2,
                                width: strSize.width, height: strSize.height),
                     withAttributes: attrs)
        }

        // --- Current time ---
        let now = Date()
        let calendar = Calendar.current
        let hour = CGFloat(calendar.component(.hour, from: now) % 12)
        let minute = CGFloat(calendar.component(.minute, from: now))
        let second = CGFloat(calendar.component(.second, from: now))
        let nano = CGFloat(calendar.component(.nanosecond, from: now)) / 1_000_000_000.0

        let smoothSecond = second + nano

        let hourAngle   = (hour + minute / 60.0) * (.pi * 2.0 / 12.0) - .pi / 2.0
        let minuteAngle = (minute + smoothSecond / 60.0) * (.pi * 2.0 / 60.0) - .pi / 2.0
        let secondAngle = smoothSecond * (.pi * 2.0 / 60.0) - .pi / 2.0

        // Shadow for hands
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 1, height: 1)
        shadow.shadowBlurRadius = 3
        shadow.set()

        // Hour hand
        drawHand(ctx: ctx, center: center, angle: hourAngle,
                 length: radius * 0.48, tailLength: radius * 0.1,
                 width: size * 0.045,
                 color: CGColor(red: 0.9, green: 0.88, blue: 0.82, alpha: 1.0))

        // Minute hand
        drawHand(ctx: ctx, center: center, angle: minuteAngle,
                 length: radius * 0.72, tailLength: radius * 0.12,
                 width: size * 0.03,
                 color: CGColor(red: 0.9, green: 0.88, blue: 0.82, alpha: 1.0))

        // Remove shadow for second hand
        let noShadow = NSShadow()
        noShadow.shadowColor = nil
        noShadow.set()

        // Second hand
        drawSecondHand(ctx: ctx, center: center, angle: secondAngle,
                       length: radius * 0.82, tailLength: radius * 0.18,
                       width: size * 0.01,
                       color: CGColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1.0))

        // Center cap
        ctx.setFillColor(CGColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1.0))
        let capR = size * 0.03
        ctx.fillEllipse(in: CGRect(x: center.x - capR, y: center.y - capR,
                                    width: capR * 2, height: capR * 2))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0))
        let innerCapR = size * 0.012
        ctx.fillEllipse(in: CGRect(x: center.x - innerCapR, y: center.y - innerCapR,
                                    width: innerCapR * 2, height: innerCapR * 2))
    }

    private func drawHand(ctx: CGContext, center: CGPoint, angle: CGFloat,
                          length: CGFloat, tailLength: CGFloat,
                          width: CGFloat, color: CGColor) {
        let tip = CGPoint(x: center.x + _cos(angle) * length,
                          y: center.y + _sin(angle) * length)
        let tail = CGPoint(x: center.x - _cos(angle) * tailLength,
                           y: center.y - _sin(angle) * tailLength)

        let perpAngle = angle + .pi / 2.0
        let halfW = width / 2.0
        let baseLeft = CGPoint(x: center.x + _cos(perpAngle) * halfW,
                               y: center.y + _sin(perpAngle) * halfW)
        let baseRight = CGPoint(x: center.x - _cos(perpAngle) * halfW,
                                y: center.y - _sin(perpAngle) * halfW)
        let tailHalfW = halfW * 0.7
        let tailLeft = CGPoint(x: tail.x + _cos(perpAngle) * tailHalfW,
                               y: tail.y + _sin(perpAngle) * tailHalfW)
        let tailRight = CGPoint(x: tail.x - _cos(perpAngle) * tailHalfW,
                                y: tail.y - _sin(perpAngle) * tailHalfW)

        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: tailLeft)
        ctx.addLine(to: baseLeft)
        ctx.addLine(to: tip)
        ctx.addLine(to: baseRight)
        ctx.addLine(to: tailRight)
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawSecondHand(ctx: CGContext, center: CGPoint, angle: CGFloat,
                                length: CGFloat, tailLength: CGFloat,
                                width: CGFloat, color: CGColor) {
        let tip = CGPoint(x: center.x + _cos(angle) * length,
                          y: center.y + _sin(angle) * length)
        let tail = CGPoint(x: center.x - _cos(angle) * tailLength,
                           y: center.y - _sin(angle) * tailLength)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: tail)
        ctx.addLine(to: tip)
        ctx.strokePath()

        // Counterweight circle on tail
        let cwRadius = width * 2.5
        let cwCenter = CGPoint(x: center.x - _cos(angle) * tailLength * 0.6,
                               y: center.y - _sin(angle) * tailLength * 0.6)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: cwCenter.x - cwRadius, y: cwCenter.y - cwRadius,
                                    width: cwRadius * 2, height: cwRadius * 2))
    }
}
