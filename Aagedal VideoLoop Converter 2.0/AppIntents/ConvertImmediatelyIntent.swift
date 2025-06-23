import AppIntents
import UniformTypeIdentifiers
import Foundation

// Notification carrying file URL and output folder URL
extension Notification.Name {
    static let convertImmediately = Notification.Name("convertImmediately")
}

struct ConvertImmediatelyIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Video Immediately"
    static let description = IntentDescription("Add the selected video file to the queue, set the output folder to the same directory, and start conversion.")

    @Parameter(title: "Video File", supportedContentTypes: [.movie])
    var video: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$video) immediately")
    }

    func perform() async throws -> some IntentResult {
        guard let url = video.fileURL else {
            throw NSError(domain: "ConvertImmediatelyIntent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])
        }

        // Prepare payload
        let folder = url.deletingLastPathComponent()
        await MainActor.run {
            NotificationCenter.default.post(name: .convertImmediately,
                                            object: nil,
                                            userInfo: [
                                                "fileURL": url,
                                                "outputFolderURL": folder
                                            ])
        }
        return .result()
    }
}
