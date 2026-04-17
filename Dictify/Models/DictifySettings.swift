import Foundation
import SwiftUI

@MainActor
final class DictifySettings: ObservableObject {
    @AppStorage("activationKey") var activationKey: String = "fn"
    @AppStorage("refinementEnabled") var refinementEnabled: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("soundEffectsEnabled") var soundEffectsEnabled: Bool = true
    @AppStorage("showElapsedTime") var showElapsedTime: Bool = true
    @AppStorage("tapHoldThreshold") var tapHoldThreshold: Double = 0.2
}
