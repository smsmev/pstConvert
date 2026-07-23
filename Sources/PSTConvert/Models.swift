import Foundation

enum OutputStructure: String, CaseIterable, Identifiable {
    case combined
    case perFolder
    case perEmail
    case binder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: return "One combined PDF"
        case .perFolder: return "One PDF per folder"
        case .perEmail: return "One PDF per email"
        case .binder: return "Combined PDF Binder"
        }
    }

    var subtitle: String {
        switch self {
        case .combined: return "All emails in a single PDF, in folder order"
        case .perFolder: return "One PDF per PST folder (Inbox, Sent, etc.)"
        case .perEmail: return "Every email becomes its own PDF"
        case .binder: return "One PDF with every email and attachment merged in — images and PDFs become pages; other files get a placeholder page and are saved alongside"
        }
    }
}

enum ConversionPhase: Equatable {
    case idle
    case extracting
    case rendering(current: Int, total: Int)
    case finishing
    case done(outputURL: URL)
    case cancelled
    case failed(message: String)

    var isRunning: Bool {
        switch self {
        case .extracting, .rendering, .finishing: return true
        default: return false
        }
    }
}

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
