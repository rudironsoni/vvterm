//
//  GhosttyTerminalGestureRouting+iOS.swift
//  VVTerm
//
//  iOS terminal gesture-recognizer routing.
//

#if os(iOS)
import UIKit
import os

// MARK: - Gesture Recognizer Delegate

extension GhosttyTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer == nativeSelectionHandlePanRecognizer {
            guard #available(iOS 17.0, *) else { return false }
            let point = touch.location(in: self)
            guard canInteractWithTerminalContent,
                  let handle = nativeSelectionHandle(at: point),
                  let range = nativeSelectedRange else {
                nativeSelectionHandleDrag = nil
                return false
            }
            let offset = handle == .start ? range.location : nativeSelectionSnapshot.upperBound(of: range)
            let caret = nativeSelectionSnapshot.caretRect(for: offset)
            // UIKit may reset pan translation when recognition starts. Retain the
            // accepted touch position instead of reconstructing it at that point.
            nativeSelectionHandleDrag = (handle, CGPoint(x: caret.minX - point.x, y: caret.midY - point.y))
            return true
        }
        if gestureRecognizer == nativeSelectionLongPressRecognizer {
            guard canInteractWithTerminalContent else { return false }
            return !isPointOnNativeSelectionHandleHitArea(touch.location(in: self))
        }
        if gestureRecognizer == directTouchTapRecognizer {
            guard canInteractWithTerminalContent else { return false }
            let location = touch.location(in: self)
            return !isPointOnNativeSelectionHandleHitArea(location)
        }
        if gestureRecognizer == pinchRecognizer {
            return canHandlePinchZoom
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == scrollRecognizer {
            return canInteractWithTerminalContent
                && !hasActiveSelectionInteraction
                && !isPinchingTerminalZoom
                && shouldAllowScrollGesture(gestureRecognizer, touchType: .indirectPointer)
        }

        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer == nativeSelectionHandlePanRecognizer || otherGestureRecognizer == nativeSelectionHandlePanRecognizer {
            return false
        }
        if gestureRecognizer == directTouchTapRecognizer || otherGestureRecognizer == directTouchTapRecognizer {
            return false
        }
        if nativeSelectionInteractionActive || nativeSelectedRange != nil,
           gestureRecognizer == scrollRecognizer || otherGestureRecognizer == scrollRecognizer {
            return false
        }
        if gestureRecognizer == pinchRecognizer || otherGestureRecognizer == pinchRecognizer {
            return false
        }
        // Allow the remaining compatible gestures to recognize simultaneously.
        return true
    }
}

extension GhosttyTerminalView {
    var allowsHostTextSelection: Bool {
        TerminalSelectionRoutingPolicy.shouldAllowHostSelection(
            terminalMouseCaptured: surface?.mouseCaptured == true,
            selectionInteractionActive: hasActiveSelectionInteraction
        )
    }

    var hasActiveSelectionInteraction: Bool {
        nativeSelectionInteractionActive
            || nativeSelectedRange != nil
            || prefersNativeSelectionFirstResponder
    }

    func shouldAllowScrollGesture(
        _ gestureRecognizer: UIGestureRecognizer,
        touchType: UITouch.TouchType
    ) -> Bool {
        TerminalPointerInputRoutingPolicy.shouldAllowScrollGesture(
            isIndirectPointer: touchType == .indirectPointer,
            isPointerButtonPressed: !gestureRecognizer.buttonMask.isEmpty,
            hasActiveTerminalPointerButton: activePointerButton != nil
        )
    }
}

extension GhosttyTerminalView {
    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if terminalScrollView.isDecelerating { stopTerminalScrolling() }
        if handleIndirectPointerTouchesBegan(touches, event: event) {
            return
        }
        // A drag must not open the keyboard or resize the terminal. Only a
        // completed tap below acquires text input.
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if handleIndirectPointerTouchesMoved(touches, event: event) {
            return
        }
        // Pan gesture handles scrolling, long press handles selection
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        _ = handleIndirectPointerTouchesEnded(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        _ = handleIndirectPointerTouchesEnded(touches, event: event)
    }

    @objc func handleDirectTouchTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              canInteractWithTerminalContent else {
            return
        }

        let selectionWasActive = hasActiveSelectionInteraction
        clearNativeSelectionStateForTerminalInput()
        if selectionWasActive {
            _ = requestKeyboardFocus(for: .directTouch)
        }

        if !selectionWasActive, routeLink(at: recognizer.location(in: self), activate: true) {
            return
        }

        if Date() >= suppressDirectTouchKeyboardFocusUntil {
            notifyDirectTouchOnTerminal(isFocusTap: true)
            requestKeyboardFocus(for: .directTouch)
        }

        // Local selection and links remain available while Chat owns text input.
        guard terminalInputAcquisitionAllowed else {
            return
        }

        guard let surface,
              TerminalPointerInputRoutingPolicy.shouldSendDirectTouchClick(
                  terminalMouseCaptured: surface.mouseCaptured,
                  terminalInputAvailable: true,
                  selectionInteractionActive: selectionWasActive
              ) else {
            return
        }

        let position = ghosttyPoint(recognizer.location(in: self))
        stopTerminalScrolling()
        surface.sendMousePos(.init(x: position.x, y: position.y, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        requestRender()
    }

    private func routeLink(at location: CGPoint, activate: Bool) -> Bool {
        // Probing during mouse capture would send unwanted motion to the remote app.
        guard canInteractWithTerminalContent,
              !hasActiveSelectionInteraction, let surface,
              !surface.mouseCaptured else { return false }
        let point = ghosttyPoint(location)
        // Ghostty uses Command for link hit testing on Apple platforms.
        surface.sendMousePos(.init(x: point.x, y: point.y, mods: .super))
        defer {
            surface.sendMousePos(.init(x: point.x, y: point.y, mods: []))
        }
        guard linkHoverState.withLock({ $0 }) else { return false }
        if activate {
            stopTerminalScrolling()
            surface.sendMouseButton(.init(action: .press, button: .left, mods: .super))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: .super))
            requestRender()
        }
        return true
    }

    func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    func firstIndirectPointerTouch(in touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .indirectPointer }
    }

    func pointerModifiers(from event: UIEvent?) -> Ghostty.Input.Mods {
        TerminalPointerInputRoutingPolicy.ghosttyModifiers(from: event?.modifierFlags ?? [])
    }

    func pointerButton(
        from event: UIEvent?
    ) -> TerminalPointerButton? {
        TerminalPointerInputRoutingPolicy.pointerButton(
            for: event?.buttonMask ?? [],
            modifiers: event?.modifierFlags ?? []
        )
    }

    func sendPointerPosition(_ location: CGPoint, mods: Ghostty.Input.Mods) {
        guard let surface else { return }
        let pos = ghosttyPoint(location)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: mods))
    }

    @discardableResult
    func handleIndirectPointerTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?) -> Bool {
        guard let touch = firstIndirectPointerTouch(in: touches) else { return false }
        guard canRouteTerminalInput, let surface else { return true }

        focusForHardwareKeyboardIfNeeded()

        let location = touch.location(in: self)
        let mods = pointerModifiers(from: event)
        sendPointerPosition(location, mods: mods)

        guard let button = pointerButton(from: event) else {
            requestRender()
            return true
        }

        activePointerButton = button
        if button == .left {
            stopTerminalScrolling()
            updateSelectionAutoscroll(location: location, mods: mods)
        } else {
            stopSelectionAutoscroll()
        }
        let handled = surface.sendMouseButton(.init(action: .press, button: button.ghosttyMouseButton, mods: mods))
        requestRender()

        if TerminalPointerInputRoutingPolicy.shouldShowHostContextMenu(
            button: button,
            terminalHandledButtonPress: handled,
            terminalMouseCaptured: surface.mouseCaptured
        ) {
            showPointerContextMenu(at: location)
        }

        return true
    }

    @discardableResult
    func handleIndirectPointerTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) -> Bool {
        guard let touch = firstIndirectPointerTouch(in: touches) else { return false }
        guard canRouteTerminalInput else { return true }

        let location = touch.location(in: self)
        let mods = pointerModifiers(from: event)
        sendPointerPosition(location, mods: mods)
        if activePointerButton == .left {
            updateSelectionAutoscroll(location: location, mods: mods)
        }
        requestRender()
        return true
    }

    @discardableResult
    func handleIndirectPointerTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?) -> Bool {
        guard let touch = firstIndirectPointerTouch(in: touches) else { return false }
        guard canRouteTerminalInput, let surface else {
            activePointerButton = nil
            stopSelectionAutoscroll()
            return true
        }

        let mods = pointerModifiers(from: event)
        sendPointerPosition(touch.location(in: self), mods: mods)
        if let button = activePointerButton {
            _ = surface.sendMouseButton(.init(action: .release, button: button.ghosttyMouseButton, mods: mods))
        }
        activePointerButton = nil
        stopSelectionAutoscroll()
        requestRender()
        return true
    }

    @objc func handlePointerHover(_ recognizer: UIHoverGestureRecognizer) {
        guard canRouteTerminalInput, let surface else { return }
        let mods = TerminalPointerInputRoutingPolicy.ghosttyModifiers(from: recognizer.modifierFlags)

        switch recognizer.state {
        case .began, .changed:
            sendPointerPosition(recognizer.location(in: self), mods: mods)
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: -1, y: -1, mods: mods))
        default:
            return
        }

        requestRender()
    }

    func updateSelectionAutoscroll(location: CGPoint, mods: Ghostty.Input.Mods) {
        guard allowsHostTextSelection,
              TerminalSelectionAutoscrollPolicy.decision(
                locationY: Double(location.y - selectionAutoscrollViewport.minY),
                viewportHeight: Double(selectionAutoscrollViewport.height),
                edgeInset: Self.selectionAutoscrollEdgeInset,
                maximumScrollDelta: Self.selectionAutoscrollMaximumDelta
              ) != nil else {
            stopSelectionAutoscroll()
            return
        }

        selectionAutoscrollLocation = location
        selectionAutoscrollMods = mods
        startSelectionAutoscrollIfNeeded()
    }

    func startSelectionAutoscrollIfNeeded() {
        guard selectionAutoscrollDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(selectionAutoscrollTick))
        displayLink.add(to: .main, forMode: .common)
        selectionAutoscrollDisplayLink = displayLink
    }

    func stopSelectionAutoscroll() {
        selectionAutoscrollDisplayLink?.invalidate()
        selectionAutoscrollDisplayLink = nil
        selectionAutoscrollLocation = nil
        selectionAutoscrollRemainder = 0
        selectionAutoscrollMods = []
    }

    var selectionAutoscrollViewport: CGRect {
        var visible = bounds
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds || view is UIWindow {
                visible = visible.intersection(view.convert(view.bounds, to: self))
            }
            ancestor = view.superview
        }
        return visible.isNull ? .zero : visible
    }

    func clampedSelectionAutoscrollLocation(_ location: CGPoint) -> CGPoint {
        let viewport = selectionAutoscrollViewport
        return CGPoint(
            x: min(max(location.x, viewport.minX), viewport.maxX),
            y: min(max(location.y, viewport.minY), viewport.maxY)
        )
    }

    @objc func selectionAutoscrollTick() {
        guard let surface,
              let location = selectionAutoscrollLocation,
              allowsHostTextSelection else {
            stopSelectionAutoscroll()
            return
        }

        guard let decision = TerminalSelectionAutoscrollPolicy.decision(
            locationY: Double(location.y - selectionAutoscrollViewport.minY),
            viewportHeight: Double(selectionAutoscrollViewport.height),
            edgeInset: Self.selectionAutoscrollEdgeInset,
            maximumScrollDelta: Self.selectionAutoscrollMaximumDelta
        ) else {
            stopSelectionAutoscroll()
            return
        }

        if nativeSelectionDragAnchor != nil {
            guard nativeSelectionInteractionActive, canInteractWithTerminalContent else {
                stopSelectionAutoscroll()
                return
            }
            // Extend from the latest viewport first. Binding actions scroll the host
            // buffer and never send wheel events to a mouse-capturing remote app.
            if nativeSelectionHandleDrag != nil {
                moveNativeSelectionHandle(to: location)
            } else {
                extendNativeSelection(to: location)
            }
            let duration = selectionAutoscrollDisplayLink.map { $0.targetTimestamp - $0.timestamp } ?? (1.0 / 60)
            selectionAutoscrollRemainder -= decision.scrollDelta * min(max(duration, 0), 0.1) * 60 / max(Double(cellSize.height), 1)
            let rows = Int(selectionAutoscrollRemainder.rounded(.towardZero))
            if rows != 0 {
                selectionAutoscrollRemainder -= Double(rows)
                if !surface.perform(action: "scroll_page_lines:\(rows)") { stopSelectionAutoscroll() }
            }
            requestRender()
            return
        }

        let clampedLocation = clampedSelectionAutoscrollLocation(location)
        let pos = ghosttyPoint(clampedLocation)
        let mousePos = Ghostty.Input.MousePosEvent(
            x: pos.x,
            y: pos.y,
            mods: selectionAutoscrollMods
        )
        surface.sendMousePos(mousePos)
        surface.sendMouseScroll(
            Ghostty.Input.MouseScrollEvent(
                x: 0,
                y: decision.scrollDelta * Double(contentScaleFactor),
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
        )
        surface.sendMousePos(mousePos)
        requestRender()
    }

    func stopTerminalScrolling() {
        terminalScrollView.stopScrolling()
    }

    @objc func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        guard canHandlePinchZoom else {
            isPinchingTerminalZoom = false
            return
        }

        switch recognizer.state {
        case .began:
            isPinchingTerminalZoom = true
            pinchReferenceScale = recognizer.scale
            stopTerminalScrolling()
            showZoomIndicator()
        case .changed:
            guard isPinchingTerminalZoom else { return }
            let relativeScale = recognizer.scale / pinchReferenceScale
            if relativeScale >= CGFloat(TerminalZoomPresentation.pinchZoomInThreshold) {
                if let result = onZoomAction?(.zoomIn) {
                    showZoomIndicator(fontSize: result.effectiveFontSize)
                }
                pinchReferenceScale = recognizer.scale
            } else if relativeScale <= CGFloat(TerminalZoomPresentation.pinchZoomOutThreshold) {
                if let result = onZoomAction?(.zoomOut) {
                    showZoomIndicator(fontSize: result.effectiveFontSize)
                }
                pinchReferenceScale = recognizer.scale
            }
        case .ended, .cancelled, .failed:
            isPinchingTerminalZoom = false
            pinchReferenceScale = 1
            scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorGestureEndHideDelay)
        default:
            break
        }
    }

    var canHandlePinchZoom: Bool {
        if nativeSelectionLifecycle.shouldRefreshSnapshot {
            return false
        }
        return true
    }
}

#endif
