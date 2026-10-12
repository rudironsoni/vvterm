#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class TerminalModalPresentationTests: XCTestCase {
    func testInactiveCloseAlertsDoNotOverwriteAChildPickerPresentation() {
        var presented = false
        let host = UIHostingController(rootView:
            Color.clear
                .preference(key: TerminalRouteModalPresentationPreferenceKey.self, value: true)
                .terminalCloseConfirmationAlert(isPresented: .constant(false), message: "Pane") {}
                .terminalCloseConfirmationAlert(isPresented: .constant(false), message: "Tab") {}
                .onPreferenceChange(TerminalRouteModalPresentationPreferenceKey.self) { presented = $0 }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(presented, "An inactive ancestor alert must preserve the child's modal ownership.")
    }
}
#endif
