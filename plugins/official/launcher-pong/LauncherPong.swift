// BTT-Plugin-Name: Launcher Pong
// BTT-Plugin-Identifier: com.folivora.btt.launcher.pong
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: gamecontroller.fill
// BTT-AI-Managed: true

import AppKit
import SwiftUI

final class LauncherPongPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let openGame = "open-game"
        static let gameSurface = "pong-surface"
        static let resetGame = "reset-game"
    }

    static func launcherPluginName() -> String { "Launcher Pong" }
    static func launcherPluginDescription() -> String { "Play Pong with your mouse inside the BetterTouchTool launcher." }
    static func launcherPluginIcon() -> String { "gamecontroller.fill" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.openGame
        result.title = "Play Pong"
        result.subtitle = "Mouse controls the left paddle inside the launcher."
        result.systemImageName = "gamecontroller.fill"
        result.surfaceIdentifier = IDs.gameSurface
        result.trailingHint = "Open"
        result.searchMatchPriority = 100
        result.keywords = ["pong", "game", "arcade", "play", "mouse"]

        let resetCommand = BTTLauncherPluginCommand()
        resetCommand.commandIdentifier = IDs.resetGame
        resetCommand.title = "Reset Game"
        resetCommand.subtitle = "Start a fresh round"
        resetCommand.systemImageName = "arrow.counterclockwise"
        resetCommand.closesLauncherOnSuccess = false

        let shortcut = BTTLauncherPluginShortcut()
        shortcut.character = "r"
        shortcut.modifierFlags = [.command]
        shortcut.displayKeys = ["⌘", "R"]
        resetCommand.shortcut = shortcut

        result.commands = [resetCommand]
        return [result]
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let result = BTTLauncherPluginActionResult()
        result.success = true
        result.closeLauncher = false

        if actionIdentifier == IDs.resetGame {
            NotificationCenter.default.post(name: .launcherPongResetRequested, object: nil)
            result.message = "Pong reset"
        } else {
            result.message = "Launcher Pong ready"
        }

        return result
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.openGame, surfaceIdentifier == IDs.gameSurface else { return nil }
        return LauncherPongSurface()
    }
}

private extension Notification.Name {
    static let launcherPongResetRequested = Notification.Name("LauncherPongResetRequested")
}

final class LauncherPongSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let gameModel = PongGameModel()
    private var hostView: NSView?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResetNotification),
            name: .launcherPongResetRequested,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func makeLauncherSurfaceView() -> NSView {
        let view = NSHostingView(rootView: LauncherPongRootView(model: gameModel))
        hostView = view
        return view
    }

    func launcherSurfaceDidAppear() {
        gameModel.start()
    }

    func launcherSurfaceWillDisappear() {
        gameModel.stop()
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        if let query, query.lowercased().contains("reset") {
            gameModel.resetGame()
        }
    }

    func launcherSurfacePreferredContentSize() -> CGSize {
        CGSize(width: 620, height: 420)
    }

    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: 500, height: 320)
    }

    func launcherSurfacePlaceholderText() -> String? {
        "Move your mouse over the game area"
    }

    func launcherSurfaceFooterHint() -> String? {
        "Move mouse to control the left paddle • Space pauses • R resets"
    }

    func launcherSurfaceStatusText() -> String? {
        gameModel.statusText
    }

    func launcherSurfaceKeepsLauncherPinned() -> Bool {
        true
    }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        return nil
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        switch event.keyCode {
        case 49: // space
            gameModel.togglePause()
            delegate?.requestLauncherSurfaceUpdate()
            return true
        case 15: // r
            gameModel.resetGame()
            delegate?.requestLauncherSurfaceUpdate()
            return true
        default:
            return false
        }
    }

    @objc private func handleResetNotification() {
        gameModel.resetGame()
        delegate?.requestLauncherSurfaceUpdate()
    }
}

final class PongGameModel: ObservableObject {
    struct Constants {
        static let fieldWidth: CGFloat = 560
        static let fieldHeight: CGFloat = 300
        static let paddleWidth: CGFloat = 12
        static let paddleHeight: CGFloat = 70
        static let ballSize: CGFloat = 14
        static let leftPaddleX: CGFloat = 24
        static let rightPaddleX: CGFloat = fieldWidth - 24 - paddleWidth
        static let paddleSpeed: CGFloat = 4.8
        static let aiTrackingFactor: CGFloat = 0.10
    }

    @Published var leftPaddleY: CGFloat = (Constants.fieldHeight - Constants.paddleHeight) / 2
    @Published var rightPaddleY: CGFloat = (Constants.fieldHeight - Constants.paddleHeight) / 2
    @Published var ballPosition: CGPoint = CGPoint(x: Constants.fieldWidth / 2, y: Constants.fieldHeight / 2)
    @Published var leftScore: Int = 0
    @Published var rightScore: Int = 0
    @Published var isPaused: Bool = false
    @Published var hasStarted: Bool = false

    private var displayLinkTimer: Timer?
    private var ballVelocity: CGVector = CGVector(dx: -3.4, dy: 2.7)
    private var mouseY: CGFloat = Constants.fieldHeight / 2

    var statusText: String {
        isPaused ? "Paused" : "First to 10 wins"
    }

    func start() {
        guard displayLinkTimer == nil else { return }
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(displayLinkTimer!, forMode: .common)
    }

    func stop() {
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
    }

    func resetGame() {
        leftScore = 0
        rightScore = 0
        resetRound(direction: Bool.random() ? 1 : -1)
        isPaused = false
        hasStarted = false
    }

    func togglePause() {
        isPaused.toggle()
    }

    func updateMouse(y: CGFloat, in height: CGFloat) {
        let normalized = max(0, min(height, y))
        let gameY = (normalized / max(height, 1)) * Constants.fieldHeight
        mouseY = gameY
        hasStarted = true
    }

    private func tick() {
        updateLeftPaddle()
        updateRightPaddle()

        guard !isPaused, hasStarted else { return }

        ballPosition.x += ballVelocity.dx
        ballPosition.y += ballVelocity.dy

        let ballRadius = Constants.ballSize / 2
        if ballPosition.y <= ballRadius || ballPosition.y >= Constants.fieldHeight - ballRadius {
            ballVelocity.dy *= -1
            ballPosition.y = min(max(ballPosition.y, ballRadius), Constants.fieldHeight - ballRadius)
        }

        handlePaddleCollisions()
        handleScoringIfNeeded()
    }

    private func updateLeftPaddle() {
        let targetY = mouseY - Constants.paddleHeight / 2
        leftPaddleY += (targetY - leftPaddleY) * 0.28
        leftPaddleY = max(0, min(Constants.fieldHeight - Constants.paddleHeight, leftPaddleY))
    }

    private func updateRightPaddle() {
        let targetY = ballPosition.y - Constants.paddleHeight / 2
        rightPaddleY += (targetY - rightPaddleY) * Constants.aiTrackingFactor
        rightPaddleY = max(0, min(Constants.fieldHeight - Constants.paddleHeight, rightPaddleY))
    }

    private func handlePaddleCollisions() {
        let ballFrame = CGRect(
            x: ballPosition.x - Constants.ballSize / 2,
            y: ballPosition.y - Constants.ballSize / 2,
            width: Constants.ballSize,
            height: Constants.ballSize
        )

        let leftPaddleFrame = CGRect(
            x: Constants.leftPaddleX,
            y: leftPaddleY,
            width: Constants.paddleWidth,
            height: Constants.paddleHeight
        )

        let rightPaddleFrame = CGRect(
            x: Constants.rightPaddleX,
            y: rightPaddleY,
            width: Constants.paddleWidth,
            height: Constants.paddleHeight
        )

        if ballFrame.intersects(leftPaddleFrame), ballVelocity.dx < 0 {
            bounceOffPaddle(paddleY: leftPaddleY, movingRight: true)
        } else if ballFrame.intersects(rightPaddleFrame), ballVelocity.dx > 0 {
            bounceOffPaddle(paddleY: rightPaddleY, movingRight: false)
        }
    }

    private func bounceOffPaddle(paddleY: CGFloat, movingRight: Bool) {
        let relativeImpact = (ballPosition.y - paddleY) / Constants.paddleHeight
        let centeredImpact = max(-1, min(1, (relativeImpact - 0.5) * 2))
        let speed = min(8.5, sqrt(ballVelocity.dx * ballVelocity.dx + ballVelocity.dy * ballVelocity.dy) + 0.35)
        ballVelocity.dx = movingRight ? abs(speed) : -abs(speed)
        ballVelocity.dy = centeredImpact * 4.6
        ballPosition.x += movingRight ? 3 : -3
    }

    private func handleScoringIfNeeded() {
        if ballPosition.x < -20 {
            rightScore += 1
            resetRound(direction: -1)
        } else if ballPosition.x > Constants.fieldWidth + 20 {
            leftScore += 1
            resetRound(direction: 1)
        }
    }

    private func resetRound(direction: CGFloat) {
        ballPosition = CGPoint(x: Constants.fieldWidth / 2, y: Constants.fieldHeight / 2)
        ballVelocity = CGVector(dx: 3.2 * direction, dy: CGFloat.random(in: -2.8 ... 2.8))
        hasStarted = false
    }
}

struct LauncherPongRootView: View {
    @ObservedObject var model: PongGameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Launcher Pong", systemImage: "gamecontroller.fill")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.leftScore) : \(model.rightScore)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            Text(model.hasStarted ? "Keep the ball alive with your mouse-controlled paddle." : "Move your mouse inside the arena to serve.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            PongArenaView(model: model)
                .frame(width: PongGameModel.Constants.fieldWidth, height: PongGameModel.Constants.fieldHeight)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                }

            HStack {
                Text("Mouse = left paddle")
                Spacer()
                Text("Space = pause")
                Spacer()
                Text("R = reset")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PongArenaView: View {
    @ObservedObject var model: PongGameModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let scaleX = size.width / PongGameModel.Constants.fieldWidth
                    let scaleY = size.height / PongGameModel.Constants.fieldHeight

                    let field = CGRect(origin: .zero, size: size)
                    context.fill(Path(field), with: .color(Color.black.opacity(0.72)))

                    var dashed = Path()
                    dashed.move(to: CGPoint(x: size.width / 2, y: 0))
                    dashed.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    context.stroke(dashed, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3, dash: [8, 10]))

                    let leftPaddle = CGRect(
                        x: PongGameModel.Constants.leftPaddleX * scaleX,
                        y: model.leftPaddleY * scaleY,
                        width: PongGameModel.Constants.paddleWidth * scaleX,
                        height: PongGameModel.Constants.paddleHeight * scaleY
                    )

                    let rightPaddle = CGRect(
                        x: PongGameModel.Constants.rightPaddleX * scaleX,
                        y: model.rightPaddleY * scaleY,
                        width: PongGameModel.Constants.paddleWidth * scaleX,
                        height: PongGameModel.Constants.paddleHeight * scaleY
                    )

                    let ballRect = CGRect(
                        x: (model.ballPosition.x - PongGameModel.Constants.ballSize / 2) * scaleX,
                        y: (model.ballPosition.y - PongGameModel.Constants.ballSize / 2) * scaleY,
                        width: PongGameModel.Constants.ballSize * scaleX,
                        height: PongGameModel.Constants.ballSize * scaleY
                    )

                    context.fill(Path(roundedRect: leftPaddle, cornerRadius: 6), with: .color(.white))
                    context.fill(Path(roundedRect: rightPaddle, cornerRadius: 6), with: .color(.white.opacity(0.88)))
                    context.fill(Path(ellipseIn: ballRect), with: .color(.green))
                }

                if model.isPaused {
                    Text("Paused")
                        .font(.title2.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                } else if !model.hasStarted {
                    Text("Move mouse here to serve")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    model.updateMouse(y: location.y, in: proxy.size.height)
                case .ended:
                    break
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
