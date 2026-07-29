import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    private let positionKey = "NSWindowLastPosition"

    /// The minimum size we consider a "sane" terminal window frame.
    /// Frames smaller than this are transient artifacts of window
    /// construction (toolbar/sidebar layout passes can momentarily
    /// shrink the window to a sliver, e.g. 1x32) and must never be
    /// persisted nor restored, otherwise every subsequent window is
    /// restored invisible.
    private static let minSaneSize = NSSize(width: 320, height: 240)

    /// The default frame size used when no valid saved frame exists.
    private static let defaultSize = NSSize(width: 1273, height: 817)

    @discardableResult
    func save(_ window: NSWindow?) -> Bool {
        // We should only save the frame if the window is visible.
        // This avoids overriding the previously saved one
        // with the wrong one when window decorations change while creating,
        // e.g. adding a toolbar affects the window's frame.
        guard let window, window.isVisible else { return false }
        let frame = window.frame

        // Never persist degenerate frames (e.g. 1x32 slivers produced
        // during window construction). Restoring such a frame makes new
        // windows effectively invisible.
        guard frame.size.width >= Self.minSaneSize.width,
              frame.size.height >= Self.minSaneSize.height else { return false }

        let rect = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        UserDefaults.ghostty.set(rect, forKey: positionKey)
        return true
    }

    /// Restores a previously saved window frame (or parts of it) onto the given window.
    ///
    /// - Parameters:
    ///   - window: The window whose frame should be updated.
    ///   - restoreOrigin: Whether to restore the saved position. Pass `false` when the
    ///     config specifies an explicit `window-position-x`/`window-position-y`.
    ///   - restoreSize: Whether to restore the saved size. Pass `false` when the config
    ///     specifies an explicit `window-width`/`window-height`.
    /// - Returns: `true` if the frame was modified, `false` if there was nothing to restore.
    @discardableResult
    func restore(_ window: NSWindow, origin restoreOrigin: Bool = true, size restoreSize: Bool = true) -> Bool {
        guard restoreOrigin || restoreSize else { return false }

        guard let values = UserDefaults.ghostty.array(forKey: positionKey) as? [Double],
              values.count >= 2 else { return false }

        let lastPosition = CGPoint(x: values[0], y: values[1])

        guard let screen = window.screen ?? NSScreen.main else { return false }
        let visibleFrame = screen.visibleFrame

        var newFrame = window.frame
        if restoreOrigin {
            newFrame.origin = lastPosition
        }

        if restoreSize, values.count >= 4 {
            if values[2] < Self.minSaneSize.width || values[3] < Self.minSaneSize.height {
                // 保存的宽高过小（异常数据，例如窗口构建过程中被持久化的
                // 1x32 残影），放弃整个恢复，使用默认尺寸并居中显示，
                // 同时清除坏数据避免下次再次触发。
                UserDefaults.ghostty.removeObject(forKey: positionKey)
                newFrame.size = Self.defaultSize
                newFrame.origin.x = visibleFrame.midX - newFrame.width / 2
                newFrame.origin.y = visibleFrame.midY - newFrame.height / 2
                window.setFrame(newFrame, display: true)
                return true
            }
            newFrame.size.width = min(values[2], visibleFrame.width)
            newFrame.size.height = min(values[3], visibleFrame.height)
        }

        // If the new frame is not constrained to the visible screen,
        // we need to shift it a little bit before AppKit does this for us,
        // so that we can save the correct size beforehand.
        // This fixes restoration while running UI tests,
        // where config is modified without switching apps,
        // which will not trigger `windowDidBecomeMain`.
        if restoreOrigin, !visibleFrame.contains(newFrame) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }

        window.setFrame(newFrame, display: true)
        return true
    }
}
