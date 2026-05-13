// BTT-Plugin-Name: Launcher FallingBlocks2
// BTT-Plugin-Identifier: com.folivora.btt.launcher.fallingblocks
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: square.grid.3x3.fill
// BTT-AI-Managed: true

import AppKit
import SwiftUI

class LauncherFallingBlocksPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let resetGame = "reset-game"
        static let gameItem = "fallingblocks-game"
        static let gameSurface = "fallingblocks-surface"
    }

    static func launcherPluginName() -> String { "Launcher FallingBlocks" }
    static func launcherPluginDescription() -> String { "Play a small FallingBlocks game directly inside the BetterTouchTool launcher." }
    static func launcherPluginIcon() -> String { "square.grid.3x3.fill" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let query = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchable = ["fallingblocks", "game", "play", "blocks", "tetromino"]
        if !query.isEmpty && !searchable.contains(where: { $0.contains(query) || query.contains($0) }) {
            return []
        }

        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.gameItem
        result.title = "Play FallingBlocks"
        result.subtitle = "Open a playable FallingBlocks board inside the launcher"
        result.systemImageName = "gamecontroller.fill"
        result.surfaceIdentifier = IDs.gameSurface
        result.trailingHint = "Open"
        result.searchMatchPriority = 100

        let resetCommand = BTTLauncherPluginCommand()
        resetCommand.commandIdentifier = IDs.resetGame
        resetCommand.title = "Reset Best Score"
        resetCommand.subtitle = "Clear the saved high score for Launcher FallingBlocks"
        resetCommand.systemImageName = "arrow.counterclockwise"
        let shortcut = BTTLauncherPluginShortcut()
        shortcut.character = "r"
        shortcut.modifierFlags = [.command, .shift]
        shortcut.displayKeys = ["⇧", "⌘", "R"]
        resetCommand.shortcut = shortcut
        resetCommand.closesLauncherOnSuccess = false

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
            delegate?.setVariable("launcherFallingBlocksHighScore", value: 0)
            result.message = "Best score reset."
            return result
        }

        result.message = "Ready to play FallingBlocks."
        return result
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.gameItem, surfaceIdentifier == IDs.gameSurface else { return nil }
        return FallingBlocksSurface(delegateProvider: { [weak self] in self?.delegate })
    }
}

final class FallingBlocksSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let delegateProvider: () -> (any BTTLauncherPluginDelegate)?
    private let gameModel = FallingBlocksGameModel()

    init(delegateProvider: @escaping () -> (any BTTLauncherPluginDelegate)?) {
        self.delegateProvider = delegateProvider
        super.init()
        if let savedHighScore = delegateProvider()?.getVariable("launcherFallingBlocksHighScore") as? NSNumber {
            gameModel.highScore = savedHighScore.intValue
        } else if let savedHighScore = delegateProvider()?.getVariable("launcherFallingBlocksHighScore") as? Int {
            gameModel.highScore = savedHighScore
        }
        gameModel.onHighScoreChanged = { [weak self] newValue in
            self?.delegateProvider()?.setVariable("launcherFallingBlocksHighScore", value: newValue)
            self?.delegate?.requestLauncherSurfaceUpdate()
        }
        gameModel.onStateChanged = { [weak self] in
            self?.delegate?.requestLauncherSurfaceUpdate()
        }
    }

    func makeLauncherSurfaceView() -> NSView {
        NSHostingView(rootView: FallingBlocksRootView(model: gameModel))
    }

    func launcherSurfaceDidAppear() {
        gameModel.start()
    }

    func launcherSurfaceWillDisappear() {
        gameModel.pause()
    }

    func launcherSurfacePlaceholderText() -> String? {
        "FallingBlocks is active — arrow keys move, space drops, R restarts"
    }

    func launcherSurfaceFooterHint() -> String? {
        "←/→ move · ↑ rotate · ↓ soft drop · Space hard drop · P pause · R restart"
    }

    func launcherSurfaceStatusText() -> String? {
        gameModel.statusText
    }

    func launcherSurfacePreferredContentSize() -> CGSize {
        CGSize(width: 560, height: 700)
    }

    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: 420, height: 560)
    }

    func launcherSurfaceKeepsLauncherPinned() -> Bool {
        true
    }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        let result = BTTLauncherPluginSurfaceCommandResult()
        switch Int(command.rawValue) {
        case 3:
            gameModel.moveLeft()
            result.handled = true
            return result
        case 4:
            gameModel.moveRight()
            result.handled = true
            return result
        case 1:
            gameModel.rotate()
            result.handled = true
            return result
        case 2:
            gameModel.softDrop()
            result.handled = true
            return result
        case 11:
            gameModel.pause()
            result.handled = true
            result.goBack = true
            return result
        case 6, 7:
            gameModel.hardDrop()
            result.handled = true
            return result
        default:
            return nil
        }
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch chars {
        case " ":
            gameModel.hardDrop()
            return true
        case "p":
            gameModel.togglePause()
            return true
        case "r":
            gameModel.restart()
            return true
        case "z":
            gameModel.rotateCounterClockwise()
            return true
        case "x":
            gameModel.rotate()
            return true
        default:
            return false
        }
    }
}

final class FallingBlocksGameModel: ObservableObject {
    static let width = 10
    static let height = 20
    private static let tickInterval: TimeInterval = 0.55

    @Published var board: [[Int]] = Array(repeating: Array(repeating: 0, count: FallingBlocksGameModel.width), count: FallingBlocksGameModel.height)
    @Published var score: Int = 0
    @Published var linesCleared: Int = 0
    @Published var level: Int = 1
    @Published var gameOver: Bool = false
    @Published var paused: Bool = false
    @Published var highScore: Int = 0

    var onHighScoreChanged: ((Int) -> Void)?
    var onStateChanged: (() -> Void)?

    private var settledBoard: [[Int]] = Array(repeating: Array(repeating: 0, count: FallingBlocksGameModel.width), count: FallingBlocksGameModel.height)
    private var activePiece: Piece?
    private var pieceOrigin = Point(x: 3, y: 0)
    private var timer: Timer?
    private var bag: [Tetromino] = []

    var statusText: String {
        if gameOver { return "Game Over · Press R to restart" }
        if paused { return "Paused" }
        return "Score \(score) · Lines \(linesCleared) · Level \(level)"
    }

    init() {
        spawnPiece()
        redrawBoard()
    }

    func start() {
        if gameOver {
            restart()
            return
        }
        paused = false
        startTimer()
        onStateChanged?()
    }

    func pause() {
        paused = true
        stopTimer()
        onStateChanged?()
    }

    func togglePause() {
        guard !gameOver else { return }
        paused.toggle()
        paused ? stopTimer() : startTimer()
        onStateChanged?()
    }

    func restart() {
        stopTimer()
        settledBoard = Array(repeating: Array(repeating: 0, count: Self.width), count: Self.height)
        board = settledBoard
        score = 0
        linesCleared = 0
        level = 1
        gameOver = false
        paused = false
        bag.removeAll()
        activePiece = nil
        pieceOrigin = Point(x: 3, y: 0)
        spawnPiece()
        redrawBoard()
        startTimer()
        onStateChanged?()
    }

    func moveLeft() { _ = attemptMove(dx: -1, dy: 0) }
    func moveRight() { _ = attemptMove(dx: 1, dy: 0) }

    func softDrop() {
        guard !paused && !gameOver else { return }
        if !attemptMove(dx: 0, dy: 1) {
            lockPiece()
        } else {
            score += 1
            updateHighScoreIfNeeded()
        }
        onStateChanged?()
    }

    func hardDrop() {
        guard !paused && !gameOver else { return }
        var dropped = 0
        while attemptMove(dx: 0, dy: 1, redraw: false) {
            dropped += 1
        }
        score += dropped * 2
        updateHighScoreIfNeeded()
        redrawBoard()
        lockPiece()
        onStateChanged?()
    }

    func rotate() {
        rotatePiece(clockwise: true)
    }

    func rotateCounterClockwise() {
        rotatePiece(clockwise: false)
    }

    private func startTimer() {
        stopTimer()
        let interval = max(0.08, Self.tickInterval - (Double(level - 1) * 0.045))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !paused && !gameOver else { return }
        if !attemptMove(dx: 0, dy: 1) {
            lockPiece()
        }
        onStateChanged?()
    }

    @discardableResult
    private func attemptMove(dx: Int, dy: Int, redraw: Bool = true) -> Bool {
        guard !paused && !gameOver, let piece = activePiece else { return false }
        let newOrigin = Point(x: pieceOrigin.x + dx, y: pieceOrigin.y + dy)
        if isValidPosition(piece.blocks, origin: newOrigin) {
            pieceOrigin = newOrigin
            if redraw { redrawBoard() }
            return true
        }
        return false
    }

    private func rotatePiece(clockwise: Bool) {
        guard !paused && !gameOver, let piece = activePiece else { return }
        let rotated = clockwise ? piece.rotatedClockwise() : piece.rotatedCounterClockwise()
        for kick in [0, -1, 1, -2, 2] {
            let origin = Point(x: pieceOrigin.x + kick, y: pieceOrigin.y)
            if isValidPosition(rotated.blocks, origin: origin) {
                activePiece = rotated
                pieceOrigin = origin
                redrawBoard()
                onStateChanged?()
                return
            }
        }
    }

    private func lockPiece() {
        guard let piece = activePiece else { return }
        for block in piece.blocks {
            let x = pieceOrigin.x + block.x
            let y = pieceOrigin.y + block.y
            guard y >= 0, y < Self.height, x >= 0, x < Self.width else { continue }
            settledBoard[y][x] = piece.type.rawValue
        }
        clearLines()
        spawnPiece()
        redrawBoard()
        onStateChanged?()
    }

    private func clearLines() {
        let remaining = settledBoard.filter { row in row.contains(0) }
        let cleared = Self.height - remaining.count
        guard cleared > 0 else { return }
        let emptyRows = Array(repeating: Array(repeating: 0, count: Self.width), count: cleared)
        settledBoard = emptyRows + remaining
        linesCleared += cleared
        let points = [0, 100, 300, 500, 800]
        score += points[min(cleared, 4)] * level
        level = max(1, (linesCleared / 10) + 1)
        updateHighScoreIfNeeded()
        startTimer()
    }

    private func spawnPiece() {
        if bag.isEmpty {
            bag = Tetromino.allCases.shuffled()
        }
        let type = bag.removeFirst()
        activePiece = Piece(type: type, blocks: type.initialBlocks)
        pieceOrigin = Point(x: 3, y: -1)
        if let blocks = activePiece?.blocks, !isValidPosition(blocks, origin: pieceOrigin) {
            gameOver = true
            stopTimer()
            updateHighScoreIfNeeded()
        }
    }

    private func isValidPosition(_ blocks: [Point], origin: Point) -> Bool {
        for block in blocks {
            let x = origin.x + block.x
            let y = origin.y + block.y
            if x < 0 || x >= Self.width || y >= Self.height { return false }
            if y >= 0 && settledBoard[y][x] != 0 { return false }
        }
        return true
    }

    private func redrawBoard() {
        var newBoard = settledBoard
        if let piece = activePiece {
            for block in piece.blocks {
                let x = pieceOrigin.x + block.x
                let y = pieceOrigin.y + block.y
                if y >= 0 && y < Self.height && x >= 0 && x < Self.width {
                    newBoard[y][x] = piece.type.rawValue
                }
            }
        }
        board = newBoard
    }

    private func updateHighScoreIfNeeded() {
        if score > highScore {
            highScore = score
            onHighScoreChanged?(highScore)
        }
    }
}

struct Point: Hashable {
    let x: Int
    let y: Int
}

enum Tetromino: Int, CaseIterable {
    case i = 1, o, t, s, z, j, l

    var initialBlocks: [Point] {
        switch self {
        case .i: return [Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1), Point(x: 3, y: 1)]
        case .o: return [Point(x: 1, y: 0), Point(x: 2, y: 0), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .t: return [Point(x: 1, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .s: return [Point(x: 1, y: 0), Point(x: 2, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1)]
        case .z: return [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .j: return [Point(x: 0, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .l: return [Point(x: 2, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        }
    }

    var color: Color {
        switch self {
        case .i: return Color(red: 0.20, green: 0.85, blue: 0.95)
        case .o: return Color(red: 0.98, green: 0.83, blue: 0.22)
        case .t: return Color(red: 0.72, green: 0.42, blue: 0.95)
        case .s: return Color(red: 0.31, green: 0.82, blue: 0.43)
        case .z: return Color(red: 0.94, green: 0.32, blue: 0.32)
        case .j: return Color(red: 0.29, green: 0.48, blue: 0.95)
        case .l: return Color(red: 0.97, green: 0.58, blue: 0.21)
        }
    }
}

struct Piece {
    let type: Tetromino
    let blocks: [Point]

    func rotatedClockwise() -> Piece {
        guard type != .o else { return self }
        let rotated = blocks.map { Point(x: 1 - $0.y, y: $0.x) }
        return Piece(type: type, blocks: Piece.normalize(rotated))
    }

    func rotatedCounterClockwise() -> Piece {
        guard type != .o else { return self }
        let rotated = blocks.map { Point(x: $0.y, y: 1 - $0.x) }
        return Piece(type: type, blocks: Piece.normalize(rotated))
    }

    private static func normalize(_ blocks: [Point]) -> [Point] {
        let minX = blocks.map(\.x).min() ?? 0
        let minY = blocks.map(\.y).min() ?? 0
        return blocks.map { Point(x: $0.x - minX, y: $0.y - minY) }
    }
}

struct FallingBlocksRootView: View {
    @ObservedObject var model: FallingBlocksGameModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Launcher FallingBlocks", systemImage: "gamecontroller.fill")
                        .font(.title2.weight(.bold))
                    Text("Play directly inside BetterTouchTool's launcher.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    StatRow(title: "Score", value: "\(model.score)")
                    StatRow(title: "Best", value: "\(model.highScore)")
                    StatRow(title: "Lines", value: "\(model.linesCleared)")
                    StatRow(title: "Level", value: "\(model.level)")
                    HStack(spacing: 8) {
                        Button(model.paused ? "Resume" : "Pause") {
                            model.togglePause()
                        }
                        Button("Restart") {
                            model.restart()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Controls")
                            .font(.headline)
                        Text("←/→ move")
                        Text("↑ or X rotate")
                        Text("Z rotate back")
                        Text("↓ soft drop")
                        Text("Space hard drop")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 170, alignment: .topLeading)

                FallingBlocksBoardView(board: model.board)
                    .frame(maxWidth: .infinity)
            }

            Text(model.gameOver ? "Game Over — press Restart" : (model.paused ? "Paused" : "Keep stacking lines"))
                .font(.headline)
                .foregroundStyle(model.gameOver ? Color.red : .primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .padding(12)
    }
}

struct StatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.system(.body, design: .rounded))
    }
}

struct FallingBlocksBoardView: View {
    let board: [[Int]]

    var body: some View {
        GeometryReader { proxy in
            let cellSize = min(proxy.size.width / CGFloat(FallingBlocksGameModel.width), proxy.size.height / CGFloat(FallingBlocksGameModel.height))
            let totalWidth = cellSize * CGFloat(FallingBlocksGameModel.width)
            let totalHeight = cellSize * CGFloat(FallingBlocksGameModel.height)

            VStack(spacing: 0) {
                ForEach(0..<FallingBlocksGameModel.height, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<FallingBlocksGameModel.width, id: \.self) { column in
                            let value = board[row][column]
                            Rectangle()
                                .fill(color(for: value))
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.white.opacity(value == 0 ? 0.06 : 0.14), lineWidth: 1)
                                )
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
            .frame(width: totalWidth, height: totalHeight)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func color(for value: Int) -> Color {
        guard let tetromino = Tetromino(rawValue: value) else {
            return Color.white.opacity(0.05)
        }
        return tetromino.color
    }
}
