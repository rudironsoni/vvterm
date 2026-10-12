#if os(iOS)
import UIKit

/// The sidebar owns the native bar. Detail content owns its SwiftUI toolbar.
final class ServerNavigationController: UINavigationController, UINavigationControllerDelegate {
    private let column: UISplitViewController.Column

    init(rootViewController: UIViewController, column: UISplitViewController.Column) {
        self.column = column
        super.init(rootViewController: rootViewController)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNavigationBar()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateNavigationBar()
    }

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController, animated: Bool) {
        let hidden = column != .primary || viewController !== viewControllers.first
        setNavigationBarHidden(hidden, animated: animated)
    }

    private func updateNavigationBar() {
        let hidden = column != .primary || topViewController !== viewControllers.first
        guard isNavigationBarHidden != hidden else { return }
        setNavigationBarHidden(hidden, animated: false)
    }
}
#endif
