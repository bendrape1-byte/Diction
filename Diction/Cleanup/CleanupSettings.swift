import Foundation

enum CleanupBackendOption: String, CaseIterable, Identifiable {
    case localModels

    var id: String { rawValue }

    var title: String {
        "Local Models"
    }
}
