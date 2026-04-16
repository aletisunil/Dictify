import Foundation
import Combine

final class AudioLevelProvider: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0, count: 15)

    func update(_ newLevels: [Float]) {
        levels = newLevels
    }

    func reset() {
        levels = Array(repeating: 0, count: 15)
    }
}
