import Foundation

/// Native renderer crash-page payload, mirrored from Chromium via the
/// `showCrashPage:windowId:data:` bridge event. Every display string is
/// produced by Chromium (the Mac side carries zero crash-page copy); the
/// authoritative `data` dictionary keys live in `PhiChromiumBridgeHeader.h`.
struct CrashPageData: Equatable {
    /// Behaviour of the primary action button.
    enum PrimaryAction {
        case reload
        case feedback
    }

    let title: String
    let message: String
    /// Primary action button label (already localized by Chromium).
    let buttonLabel: String
    let helpLinkLabel: String
    /// Symbolized error-code line; an empty string hides the row.
    let errorCodeText: String
    /// Troubleshooting suggestions, non-empty only when repeatedly crashing.
    let tips: [String]
    let helpLinkUrl: String
    let showFeedbackButton: Bool
    let isRepeatedlyCrashing: Bool
    let errorCode: Int
    let kind: Int
    let terminationStatus: Int

    var primaryAction: PrimaryAction {
        .reload
    }

    init(dictionary: [AnyHashable: Any]) {
        title = dictionary["title"] as? String ?? ""
        message = dictionary["message"] as? String ?? ""
        let upstreamButtonLabel = dictionary["buttonLabel"] as? String ?? ""
        helpLinkLabel = dictionary["helpLinkLabel"] as? String ?? ""
        errorCodeText = dictionary["errorCodeText"] as? String ?? ""
        tips = dictionary["tips"] as? [String] ?? []
        helpLinkUrl = dictionary["helpLinkUrl"] as? String ?? ""
        showFeedbackButton = (dictionary["showFeedbackButton"] as? NSNumber)?.boolValue ?? false
        buttonLabel = showFeedbackButton
            ? NSLocalizedString("Reload", comment: "Renderer crash page - Reload button")
            : upstreamButtonLabel
        isRepeatedlyCrashing = (dictionary["isRepeatedlyCrashing"] as? NSNumber)?.boolValue ?? false
        errorCode = (dictionary["errorCode"] as? NSNumber)?.intValue ?? 0
        kind = (dictionary["kind"] as? NSNumber)?.intValue ?? 0
        terminationStatus = (dictionary["terminationStatus"] as? NSNumber)?.intValue ?? 0
    }
}
