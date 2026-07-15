import Cocoa
import ApplicationServices
import Carbon

final class AccessibilityInserter: @unchecked Sendable {
    struct InsertionResult {
        let inserted: Bool
        let diagnostics: Diagnostics
    }

    struct Diagnostics {
        enum PasteFailureCause: String {
            case noFocusedElement = "no_focused_element"
            case focusedElementNotEditable = "focused_element_not_editable"
            case secureOrProtectedField = "secure_or_protected_field"
            case keystrokeInjectionRejected = "keystroke_injection_rejected"
        }

        var frontmostBundleID: String
        var frontmostPID: pid_t?
        var focusedElementExists = false
        var focusedElementError: AXError?
        var role: String?
        var subrole: String?
        var supportsSelectedTextRange: Bool?
        var selectedTextRangeError: AXError?
        var valueSettable: Bool?
        var valueSettableError: AXError?
        var supportsInsertTextAction: Bool?
        var insertTextActionError: AXError?
        var protectedContent: Bool?
        var protectedContentError: AXError?
        var secureEventInputEnabled = false
        var postEventAccessGranted = false
        var selectedTextSetError: AXError?
        var valueSetError: AXError?
        var skippedForBundlePolicy = false

        var isSecureOrProtected: Bool {
            secureEventInputEnabled
                || protectedContent == true
                || subrole == (kAXSecureTextFieldSubrole as String)
        }

        var isEditableCandidate: Bool {
            supportsSelectedTextRange == true
                || valueSettable == true
                || supportsInsertTextAction == true
        }

        var pasteFailureCause: PasteFailureCause? {
            if !focusedElementExists {
                return .noFocusedElement
            }

            if isSecureOrProtected {
                return .secureOrProtectedField
            }

            if !isEditableCandidate {
                return .focusedElementNotEditable
            }

            if !postEventAccessGranted {
                return .keystrokeInjectionRejected
            }

            return nil
        }
    }

    @MainActor
    func insert(_ text: String) async -> InsertionResult {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var diagnostics = Diagnostics(
            frontmostBundleID: bundleID ?? "unknown",
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        diagnostics.secureEventInputEnabled = IsSecureEventInputEnabled()
        diagnostics.postEventAccessGranted = CGPreflightPostEventAccess()

        // Apps known to break AX insertion (Slack/Discord/Notion/WhatsApp) —
        // skip straight to clipboard without wasting a verification round-trip.
        if ClipboardPaster.shouldSkipAccessibilityFor(bundleID: bundleID) {
            diagnostics.skippedForBundlePolicy = true
            return InsertionResult(inserted: false, diagnostics: diagnostics)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            diagnostics.focusedElementError = result
            return InsertionResult(inserted: false, diagnostics: diagnostics)
        }

        diagnostics.focusedElementExists = true
        let axElement = focusedElement as! AXUIElement
        diagnostics.role = Self.stringAttribute(axElement, kAXRoleAttribute as CFString)
        diagnostics.subrole = Self.stringAttribute(axElement, kAXSubroleAttribute as CFString)
        diagnostics.supportsSelectedTextRange = Self.supportsAttribute(axElement, kAXSelectedTextRangeAttribute as CFString)
        diagnostics.selectedTextRangeError = Self.copyAttributeError(axElement, kAXSelectedTextRangeAttribute as CFString)
        (diagnostics.valueSettable, diagnostics.valueSettableError) = Self.isAttributeSettable(axElement, kAXValueAttribute as CFString)
        (diagnostics.supportsInsertTextAction, diagnostics.insertTextActionError) = Self.supportsAction(axElement, "AXInsertText" as CFString)
        (diagnostics.protectedContent, diagnostics.protectedContentError) = Self.boolAttribute(axElement, NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString)

        // Never inject into password / secure fields.
        if diagnostics.isSecureOrProtected {
            return InsertionResult(inserted: false, diagnostics: diagnostics)
        }

        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXWebArea"
        ]

        let snapshotBeforeInsertion = Self.textSnapshot(axElement)

        // Try selected text replacement first (inserts at cursor without replacing all)
        let selectedTextResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedTextResult == .success {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let verification = Self.verifyInsertion(text, before: snapshotBeforeInsertion, element: axElement)

            if verification.committed {
                return InsertionResult(inserted: true, diagnostics: diagnostics)
            }

            diagnostics.selectedTextSetError = selectedTextResult
            return InsertionResult(inserted: false, diagnostics: diagnostics)
        }
        diagnostics.selectedTextSetError = selectedTextResult

        // Setting kAXValueAttribute replaces the field's ENTIRE contents, so it
        // is only safe when the field is currently empty (replacement ==
        // insertion). A non-empty field falls through to clipboard paste, which
        // inserts at the caret instead of wiping what the user already typed.
        // Also restricted to known text roles to avoid crashing non-standard
        // elements (Electron, CEF, etc.)
        let fieldIsEmpty = (snapshotBeforeInsertion.value ?? "").isEmpty
        if fieldIsEmpty, let role = diagnostics.role, textRoles.contains(role) {
            let setResult = AXUIElementSetAttributeValue(
                axElement,
                kAXValueAttribute as CFString,
                text as CFTypeRef
            )
            if setResult == .success {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let verification = Self.verifyInsertion(text, before: snapshotBeforeInsertion, element: axElement)

                if verification.committed {
                    return InsertionResult(inserted: true, diagnostics: diagnostics)
                }

                diagnostics.valueSetError = setResult
                return InsertionResult(inserted: false, diagnostics: diagnostics)
            }
            diagnostics.valueSetError = setResult
        }

        return InsertionResult(inserted: false, diagnostics: diagnostics)
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Post a VoiceOver-friendly announcement. Silent when VO is off.
    @MainActor
    static func announceInsertionSuccess() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Text inserted",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func supportsAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attributeNames = names as? [String] else {
            return false
        }

        return attributeNames.contains(attribute as String)
    }

    private static func copyAttributeError(_ element: AXUIElement, _ attribute: CFString) -> AXError {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value)
    }

    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> (Bool?, AXError) {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard result == .success else {
            return (nil, result)
        }

        return (settable.boolValue, result)
    }

    private static func supportsAction(_ element: AXUIElement, _ action: CFString) -> (Bool?, AXError) {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success,
              let actionNames = names as? [String] else {
            return (nil, result)
        }

        return (actionNames.contains(action as String), result)
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> (Bool?, AXError) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value else {
            return (nil, result)
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (CFBooleanGetValue((value as! CFBoolean)), result)
        }

        return (value as? Bool, result)
    }

    private struct TextSnapshot {
        let value: String?
        let selectedRange: CFRange?
    }

    private struct VerificationResult {
        let committed: Bool
    }

    private static func textSnapshot(_ element: AXUIElement) -> TextSnapshot {
        TextSnapshot(
            value: stringAttribute(element, kAXValueAttribute as CFString),
            selectedRange: selectedTextRange(element)
        )
    }

    private static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private static func verifyInsertion(_ text: String, before: TextSnapshot, element: AXUIElement) -> VerificationResult {
        let after = textSnapshot(element)
        let insertedLength = text.utf16.count

        if let beforeRange = before.selectedRange, let afterRange = after.selectedRange {
            let expectedLocation = beforeRange.location + insertedLength
            if afterRange.location == expectedLocation && afterRange.length == 0 {
                return VerificationResult(
                    committed: true
                )
            }
        }

        if let beforeValue = before.value, let afterValue = after.value, beforeValue != afterValue {
            return VerificationResult(
                committed: true
            )
        }

        if before.selectedRange != nil || before.value != nil || after.selectedRange != nil || after.value != nil {
            return VerificationResult(
                committed: false
            )
        }

        return VerificationResult(
            committed: true
        )
    }
}
