// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

final class OverlayToastCenterTests: XCTestCase {
    private final class ManualScheduler {
        private final class ScheduledAction {
            var isCancelled: Bool = false
            let action: () -> Void

            init(action: @escaping () -> Void) {
                self.action = action
            }
        }

        private var scheduledActions: [ScheduledAction] = []

        var pendingCount: Int {
            scheduledActions.filter { !$0.isCancelled }.count
        }

        func schedule(delay: TimeInterval, action: @escaping () -> Void) -> AnyCancellable {
            let scheduledAction = ScheduledAction(action: action)
            scheduledActions.append(scheduledAction)
            return AnyCancellable {
                scheduledAction.isCancelled = true
            }
        }

        func fireNext() {
            while !scheduledActions.isEmpty {
                let scheduledAction = scheduledActions.removeFirst()
                guard !scheduledAction.isCancelled else { continue }
                scheduledAction.action()
                return
            }
        }
    }

    func testReplacesVisibleToastForSameWindowAndPlacement() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "First", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Second", duration: 2, placement: .topCenter, in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Second"])
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.fireNext()

        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
    }

    func testIsolatesQueuesByWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "Window One", duration: 2, in: .windowId(1))
        center.show(title: "Window Two", duration: 2, in: .windowId(2))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Window One"])
        XCTAssertEqual(center.visibleToasts(for: 2).map(\.title), ["Window Two"])

        scheduler.fireNext()

        XCTAssertTrue(center.visibleToasts(for: 1).isEmpty)
        XCTAssertEqual(center.visibleToasts(for: 2).map(\.title), ["Window Two"])
    }

    func testAllowsDifferentPlacementsInSameWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)

        center.show(title: "Center", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Trailing", duration: 2, placement: .topTrailing, in: .windowId(1))

        XCTAssertEqual(center.visibleToasts(for: 1).map(\.title), ["Center", "Trailing"])
        XCTAssertEqual(scheduler.pendingCount, 2)
    }

    func testRoutesDefaultTargetToActiveWindow() {
        let scheduler = ManualScheduler()
        let center = makeCenter(
            scheduler: scheduler,
            resolver: { target in
                switch target {
                case .activeWindow:
                    return 7
                case .windowId(let windowId):
                    return windowId
                }
            }
        )

        center.show(title: "Active Window")

        XCTAssertEqual(center.visibleToasts(for: 7).map(\.title), ["Active Window"])
    }

    func testPublishesVisibleToastChanges() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        var publishedTitles: [[String]] = []
        let cancellable = center.visibleToastsPublisher(for: 1)
            .sink { toasts in
                publishedTitles.append(toasts.map(\.title))
            }

        center.show(title: "Published", duration: 2, in: .windowId(1))

        XCTAssertEqual(publishedTitles, [[], ["Published"]])

        scheduler.fireNext()

        XCTAssertEqual(publishedTitles, [[], ["Published"], []])
        cancellable.cancel()
    }

    func testPublishesReplacementForSameWindowAndPlacement() {
        let scheduler = ManualScheduler()
        let center = makeCenter(scheduler: scheduler)
        var publishedTitles: [[String]] = []
        let cancellable = center.visibleToastsPublisher(for: 1)
            .sink { toasts in
                publishedTitles.append(toasts.map(\.title))
            }

        center.show(title: "First", duration: 2, placement: .topCenter, in: .windowId(1))
        center.show(title: "Second", duration: 2, placement: .topCenter, in: .windowId(1))

        XCTAssertEqual(publishedTitles, [[], ["First"], ["Second"]])

        scheduler.fireNext()

        XCTAssertEqual(publishedTitles, [[], ["First"], ["Second"], []])
        cancellable.cancel()
    }

    func testGenericToastTopOffsetFollowsLayoutMode() {
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .comfortable), CGFloat(88))
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .performance), CGFloat(16))
        XCTAssertEqual(OverlayToastViewModel.genericToastTopOffset(for: .balanced), CGFloat(52))
    }

    private func makeCenter(
        scheduler: ManualScheduler,
        resolver: @escaping OverlayToastCenter.TargetResolver = { target in
            switch target {
            case .activeWindow:
                return nil
            case .windowId(let windowId):
                return windowId
            }
        }
    ) -> OverlayToastCenter {
        var ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ]

        return OverlayToastCenter(
            targetResolver: resolver,
            scheduler: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            idFactory: { ids.removeFirst() }
        )
    }
}
