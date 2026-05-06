// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

/// 3pt-tall rounded color line drawn under one tab group's member-tab
/// run on the horizontal strip. One layer per visible expanded group; the
/// layer pool lives on `TabStrip` keyed by token.
///
/// Frame is set in `normalContainer.layer` coordinates by `TabStrip.applyLayout`
/// from `TabStripLayoutOutput.underlineFrames[token]`; color comes from
/// `WebContentGroupInfo.color.nsColor`.
final class TabGroupUnderlineLayer: CAShapeLayer {
    /// Strip metric: line thickness.
    static let height: CGFloat = 3
    /// Strip metric: end-cap radius.
    static let cornerRadius: CGFloat = 2

    override init() {
        super.init()
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        strokeColor = NSColor.clear.cgColor
        // Path morphing animates with the surrounding NSAnimationContext
        // (TabStripAnimationHelper); fillColor changes are explicit on
        // color edits and should snap.
        actions = [
            "fillColor": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the layer's frame and rebuilds the rounded-rect path. Called
    /// every layout pass with the engine's `underlineFrames[token]` rect
    /// already converted into `normalContainer.layer` coordinates (i.e.
    /// scroll offset already applied by the caller).
    func setFrameAndPath(_ rect: CGRect) {
        frame = rect
        let bounds = CGRect(origin: .zero, size: rect.size)
        path = CGPath(
            roundedRect: bounds,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
    }

    /// Sets the fill to the saturated `GroupColor.nsColor`. Strokes stay
    /// clear — the line is a filled rounded rect, not a stroked path.
    func setColor(_ color: NSColor) {
        fillColor = color.cgColor
    }
}
