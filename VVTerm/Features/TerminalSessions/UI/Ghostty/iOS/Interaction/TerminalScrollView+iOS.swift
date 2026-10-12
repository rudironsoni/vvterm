#if os(iOS)
import UIKit
import os

/// UIKit owns scroll motion; Ghostty owns the terminal buffer and its viewport.
@MainActor
final class TerminalScrollView: UIScrollView, UIScrollViewDelegate {
    private enum Route {
        case synchronizing
        case history(row: Int, rowHeight: CGFloat)
        case remote(offset: CGPoint, remainder: CGPoint)
    }

    weak var terminalOwner: GhosttyTerminalView?
    private var route = Route.synchronizing

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        isOpaque = false
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .none
        decelerationRate = .normal
        delaysContentTouches = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        scrollsToTop = false
        isDirectionalLockEnabled = true
        panGestureRecognizer.maximumNumberOfTouches = 1
        panGestureRecognizer.requiresExclusiveTouchType = false
        // Pointer button drags belong to terminal selection, not scrolling.
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGestureRecognizer.allowedScrollTypesMask = .all
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func updateViewport(_ frame: CGRect) {
        if self.frame != frame {
            stopScrolling()
            let previous = route
            route = .synchronizing
            self.frame = frame
            route = previous
        }
        synchronize()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            guard let terminalOwner,
                  terminalOwner.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
            synchronize()
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func synchronize() {
        guard let terminal = terminalOwner,
              bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return }
        let previous = route
        route = .synchronizing
        let moving = isTracking || isDragging || isDecelerating
        let rowHeight = terminal.cellSize.height

        if let scrollbar = terminal.scrollbar,
           scrollbar.total > scrollbar.len,
           terminal.surface?.mouseCaptured != true,
           rowHeight.isFinite, rowHeight > 0 {
            let maximumRow = Int(clamping: scrollbar.total - scrollbar.len)
            let maximumOffset = CGFloat(maximumRow) * rowHeight
            guard maximumOffset.isFinite,
                  (maximumOffset + bounds.height).isFinite else {
                stopScrolling()
                return
            }
            alwaysBounceHorizontal = false
            alwaysBounceVertical = false
            contentSize = CGSize(width: bounds.width, height: bounds.height + maximumOffset)
            let coreRow = min(scrollbar.offsetAsInt, maximumRow)
            if case .history(let lastRow, let previousHeight) = previous,
               previousHeight == rowHeight,
               moving || lastRow == coreRow {
                route = .history(row: lastRow, rowHeight: rowHeight)
            } else {
                if moving { stopScrolling() }
                setContentOffset(CGPoint(x: 0, y: CGFloat(coreRow) * rowHeight), animated: false)
                route = .history(row: coreRow, rowHeight: rowHeight)
            }
        } else {
            // Remote apps do not expose their scroll limits. This is a bounded
            // input range only; it allocates no document or terminal history.
            let center = CGFloat(1 << 24)
            alwaysBounceHorizontal = false
            alwaysBounceVertical = false
            contentSize = CGSize(width: center * 2 + bounds.width, height: center * 2 + bounds.height)
            if case .remote(let offset, let remainder) = previous, moving {
                route = .remote(offset: offset, remainder: remainder)
            } else {
                if moving { stopScrolling() }
                setContentOffset(CGPoint(x: center, y: center), animated: false)
                route = .remote(offset: contentOffset, remainder: .zero)
            }
        }
    }

    func stopScrolling() {
        // Cancels UIKit deceleration on every supported iOS version.
        setContentOffset(contentOffset, animated: false)
        if isDragging {
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        synchronize()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let terminal = terminalOwner, terminal.canInteractWithTerminalContent,
              !terminal.hasActiveSelectionInteraction, let surface = terminal.surface else { return }

        switch route {
        case .synchronizing:
            return
        case .history(let previousRow, let rowHeight):
            guard rowHeight.isFinite, rowHeight > 0,
                  let scrollbar = terminal.scrollbar,
                  let row = Ghostty.Action.Scrollbar.clampedRowIndex(Double(contentOffset.y / rowHeight)) else { return }
            let boundedRow = min(row, Int(clamping: scrollbar.total - scrollbar.len))
            guard boundedRow != previousRow else { return }
            route = .history(row: boundedRow, rowHeight: rowHeight)
            // Absolute viewport actions retain fractional UIKit movement and do
            // not pass local history through remote mouse reporting or speed multipliers.
            guard surface.perform(action: "scroll_to_row:\(boundedRow)") else {
                GhosttyTerminalView.logger.error("Terminal history scroll action failed")
                stopScrolling()
                return
            }
        case .remote(let previousOffset, let remainder):
            guard terminal.canRouteTerminalInput else {
                route = .remote(offset: contentOffset, remainder: .zero)
                stopScrolling()
                return
            }
            let size = terminal.cellSize
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            let pending = CGPoint(
                x: remainder.x + previousOffset.x - contentOffset.x,
                y: remainder.y + previousOffset.y - contentOffset.y
            )
            guard let columns = Int(exactly: (pending.x / size.width).rounded(.towardZero)),
                  let rows = Int(exactly: (pending.y / size.height).rounded(.towardZero)) else {
                stopScrolling()
                return
            }
            route = .remote(
                offset: contentOffset,
                remainder: CGPoint(x: pending.x - CGFloat(columns) * size.width, y: pending.y - CGFloat(rows) * size.height)
            )
            guard columns != 0 || rows != 0 else { return }
            let modifiers = TerminalPointerInputRoutingPolicy.ghosttyModifiers(from: panGestureRecognizer.modifierFlags)
            terminal.sendPointerPosition(panGestureRecognizer.location(in: terminal), mods: modifiers)
            surface.sendMouseScroll(.init(
                x: Double(columns), y: Double(rows),
                mods: .init(precision: false, momentum: .none)
            ))
        }
        terminal.requestRender()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, case .remote = route { synchronize() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if case .remote = route { synchronize() }
    }
}
#endif
