import Foundation

// MARK: - Terminal Data Manager

/// Manages terminal data, sizing, and configuration for both macOS and iOS.
///
/// This class encapsulates the terminal state management logic that is common
/// between the local macOS display and the remote iOS streaming view.
/// Platform-specific views observe this manager and render accordingly.
///
/// Uses the composition pattern - platform-specific controllers contain a
/// TerminalDataManager rather than inheriting from it.
@Observable
@MainActor
final public class TerminalDataManager: @unchecked Sendable {
    // MARK: - Configuration

    /// Font name for the terminal
    public var fontName: String {
        didSet {
            if fontName != oldValue {
                recalculateCellSize()
            }
        }
    }

    /// Font size for the terminal
    public var fontSize: CGFloat {
        didSet {
            if fontSize != oldValue {
                recalculateCellSize()
            }
        }
    }

    // MARK: - Dimensions

    /// Current terminal width in columns
    public private(set) var columns: Int

    /// Current terminal height in rows
    public private(set) var rows: Int

    /// Calculated cell size based on font metrics
    public private(set) var cellSize: CGSize

    /// Total pixel size needed for the terminal content (excluding buffer)
    public var terminalContentSize: CGSize {
        CGSize(
            width: CGFloat(columns) * cellSize.width,
            height: CGFloat(rows) * cellSize.height
        )
    }

    /// Total pixel size including horizontal buffer for scrollbars
    public var terminalPixelSize: CGSize {
        CGSize(
            width: CGFloat(columns) * cellSize.width + FontMetrics.horizontalBuffer,
            height: CGFloat(rows) * cellSize.height
        )
    }

    // MARK: - Data Buffering

    /// The accumulated terminal data (for iOS replay on connect)
    public private(set) var bufferedData: Data

    // MARK: - Callbacks

    /// Callback when new data arrives (for platform views to consume)
    public var onData: (@MainActor (Data) -> Void)?

    /// Callback when dimensions change
    public var onDimensionChange: (@MainActor (Int, Int) -> Void)?

    // MARK: - Initialization

    /// Creates a new terminal data manager with the specified configuration.
    ///
    /// - Parameters:
    ///   - fontName: Font name for the terminal (default: "SF Mono")
    ///   - fontSize: Font size for the terminal (default: 12)
    ///   - columns: Initial terminal width in columns (default: 80)
    ///   - rows: Initial terminal height in rows (default: 24)
    public init(
        fontName: String = "SF Mono",
        fontSize: CGFloat = 12,
        columns: Int = 80,
        rows: Int = 24
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.columns = columns
        self.rows = rows
        self.bufferedData = Data()
        self.cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
    }

    // MARK: - Data Management

    /// Feed new data to the terminal.
    ///
    /// Appends to buffer and notifies observers.
    ///
    /// - Parameter data: Raw terminal data (may include ANSI escape sequences)
    public func feed(_ data: Data) {
        bufferedData.append(data)
        onData?(data)
    }

    /// Reset with initial state (for streaming start or reconnection).
    ///
    /// Clears the buffer, sets new dimensions, and feeds the initial content.
    ///
    /// - Parameters:
    ///   - data: Initial terminal buffer content
    ///   - columns: Terminal width in columns
    ///   - rows: Terminal height in rows
    public func resetWithInitialState(_ data: Data, columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        bufferedData = data
        recalculateCellSize()
        onDimensionChange?(columns, rows)
        onData?(data)
    }

    /// Resize the terminal to new dimensions.
    ///
    /// - Parameters:
    ///   - columns: New width in columns
    ///   - rows: New height in rows
    /// - Returns: True if dimensions changed, false if they were already at these values
    @discardableResult
    public func resize(columns: Int, rows: Int) -> Bool {
        guard self.columns != columns || self.rows != rows else { return false }
        self.columns = columns
        self.rows = rows
        onDimensionChange?(columns, rows)
        return true
    }

    /// Clear all buffered data.
    public func clear() {
        bufferedData = Data()
    }

    // MARK: - Private

    private func recalculateCellSize() {
        cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
    }
}
