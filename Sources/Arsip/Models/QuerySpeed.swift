import SwiftUI

/// How a finished query felt, for the badge in the editor's status bar.
enum QuerySpeed {
    case failed
    case fast
    case moderate
    case slow

    init(duration: TimeInterval, failed: Bool) {
        if failed {
            self = .failed
        } else if duration < 0.1 {
            self = .fast
        } else if duration < 1 {
            self = .moderate
        } else {
            self = .slow
        }
    }

    var symbol: String {
        switch self {
        case .failed: "xmark.octagon.fill"
        case .fast: "checkmark.circle.fill"
        case .moderate: "clock.fill"
        case .slow: "tortoise.fill"
        }
    }

    var color: Color {
        switch self {
        case .failed: .red
        case .fast: .green
        case .moderate: .orange
        case .slow: .red
        }
    }

    var explanation: String {
        switch self {
        case .failed: "The statement failed"
        case .fast: "Fast — under 100 ms"
        case .moderate: "Noticeable — 100 ms to 1 s"
        case .slow: "Slow — over 1 s. Ask Claude to look at the plan."
        }
    }
}
