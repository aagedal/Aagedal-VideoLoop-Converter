import SwiftUI

struct VideoMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    @State private var isLoadingC2PA = false
    @State private var isLoadingCamera = false

    private var metadata: VideoMetadata? { item.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Metadata")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close metadata")
                .keyboardShortcut(.escape, modifiers: [])
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    c2paSection
                    Divider()
                    cameraSection
                    Divider()
                    generalSection
                    Divider()
                    videoSection
                    Divider()
                    audioSection
                    Divider()
                    subtitleSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .task {
            await fetchC2PAIfNeeded()
            await fetchCameraMetadataIfNeeded()
        }
    }

    // MARK: - C2PA Fetching

    private func fetchC2PAIfNeeded() async {
        // Skip if already loaded or loading
        guard item.c2paMetadata == nil, !isLoadingC2PA else { return }

        isLoadingC2PA = true
        defer { isLoadingC2PA = false }

        if let c2pa = await VideoFileUtils.fetchC2PAMetadata(for: item.url) {
            item.c2paMetadata = c2pa
        }
    }

    private var generalSection: some View {
        section(title: "General") {
            infoRow("Container", value: metadata?.containerLongName ?? metadata?.formatName)
            infoRow("Duration", value: item.duration)
            infoRow("File Size", value: formattedSize)
            infoRow("Date Created", value: formattedCreationDate)
            infoRow("Date Modified", value: formattedModificationDate)
            infoRow("Bit Rate", value: formatBitRate(metadata?.bitRate))
            if let comment = item.metadataComment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Comment")
                        .font(.subheadline.weight(.semibold))
                    Text(comment)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if metadata == nil {
                Text("No detailed metadata available.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var videoSection: some View {
        section(title: "Video") {
            if let videoStreams = metadata?.videoStreams, !videoStreams.isEmpty {
                ForEach(videoStreams.indices, id: \.self) { index in
                    let stream = videoStreams[index]
                    if videoStreams.count > 1 {
                        Text("Stream \(index + 1)")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                            .padding(.top, index > 0 ? 12 : 0)
                            .padding(.bottom, 2)
                    }
                    infoRow("Codec", value: stream.codecLongName ?? stream.codec)
                    infoRow("Profile", value: stream.profile)
                    if index == 0 {
                        infoRow("Resolution", value: item.videoResolutionDescription)
                    } else if let width = stream.width, let height = stream.height {
                        infoRow("Resolution", value: "\(width) × \(height)")
                    }
                    infoRow("Display Aspect", value: stream.displayAspectRatio?.stringValue)
                    infoRow("Pixel Aspect", value: stream.pixelAspectRatio?.stringValue)
                    infoRow("Frame Rate", value: formattedFrameRate(stream.frameRate))
                    if index == 0 {
                        infoRow("Frame Count", value: metadata?.frameCount.map(String.init))
                        infoRow("Timecode", value: metadata?.timecode)
                    }
                    infoRow("Bit Depth", value: stream.bitDepth.map { "\($0)-bit" })
                    infoRow("Chroma Subsampling", value: stream.chromaSubsampling)
                    infoRow("Chroma Resolution", value: stream.chromaResolutionDescription)
                    infoRow("Pixel Format", value: stream.pixelFormat)
                    infoRow("Alpha Channel", value: stream.hasAlpha ? "Yes" : "No")
                    infoRow("Color Primaries", value: stream.colorPrimaries)
                    infoRow("Color Transfer", value: stream.colorTransfer)
                    infoRow("Color Space", value: stream.colorSpace)
                    infoRow("Color Range", value: stream.colorRange)
                    infoRow("Chroma Location", value: stream.chromaLocation)
                    infoRow("Scan Type", value: formattedScanType(stream))
                }
            } else {
                Text("No video stream detected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var audioSection: some View {
        section(title: "Audio") {
            if let audioStreams = metadata?.audioStreams, !audioStreams.isEmpty {
                ForEach(audioStreams.indices, id: \.self) { index in
                    let stream = audioStreams[index]
                    if audioStreams.count > 1 {
                        Text("Stream \(index + 1)")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                            .padding(.top, index > 0 ? 12 : 0)
                            .padding(.bottom, 2)
                    }
                    infoRow("Codec", value: stream.codecLongName ?? stream.codec)
                    infoRow("Language", value: stream.languageCode?.uppercased())
                    infoRow("Profile", value: stream.profile)
                    infoRow("Sample Rate", value: formatSampleRate(stream.sampleRate))
                    infoRow("Channels", value: stream.channels.map(String.init))
                    infoRow("Channel Layout", value: stream.channelLayout)
                    infoRow("Bit Depth", value: stream.bitDepth.map { "\($0)-bit" })
                    infoRow("Bit Rate", value: formatBitRate(stream.bitRate))
                }
            } else {
                Text("No audio stream detected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var subtitleSection: some View {
        section(title: "Subtitles") {
            if let subtitleStreams = metadata?.subtitleStreams, !subtitleStreams.isEmpty {
                ForEach(subtitleStreams.indices, id: \.self) { index in
                    let stream = subtitleStreams[index]
                    if subtitleStreams.count > 1 {
                        Text("Stream \(index + 1)")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                            .padding(.top, index > 0 ? 12 : 0)
                            .padding(.bottom, 2)
                    }
                    infoRow("Codec", value: stream.codecLongName ?? stream.codec)
                    infoRow("Language", value: stream.languageCode?.uppercased())
                    infoRow("Title", value: stream.title)
                    if stream.isDefault {
                        infoRow("Default", value: "Yes")
                    }
                    if stream.isForced {
                        infoRow("Forced", value: "Yes")
                    }
                }
            } else {
                Text("No subtitle stream detected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var c2paSection: some View {
        section(title: "Content Authenticity (C2PA)") {
            Text("Presence only. This app does not verify C2PA signatures.")
                .font(.caption)
                .foregroundColor(.secondary)

            verificationLinksView

            if isLoadingC2PA {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Checking for content credentials...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let c2pa = item.c2paMetadata, c2pa.hasContentCredentials {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("Content Credentials Present")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .padding(.bottom, 8)

                if c2pa.hasSignature {
                    infoRow("Signature", value: "Present")
                }
                infoRow("Claim Generator Info Name", value: c2pa.claimGeneratorInfoName)
                infoRow("Claim Generator", value: c2pa.claimGenerator)
                infoRow("Actions Action", value: c2pa.actionsAction)
                infoRow("Actions Digital Source Type", value: c2pa.actionsDigitalSourceType)
                infoRow("Signature Types", value: c2pa.userDescriptiveMetadataName)
                infoRow("Signature Content", value: c2pa.userDescriptiveMetadataContent)
                infoRow("C2PA Creation Date", value: c2pa.creationDateValue)
                if let manifestStore = c2pa.manifestStore, !manifestStore.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manifest Store")
                            .font(.subheadline.weight(.semibold))
                        Text(manifestStore)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                }
                if let assertions = c2pa.assertions, !assertions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Assertions")
                            .font(.subheadline.weight(.semibold))
                        ForEach(assertions, id: \.self) { assertion in
                            Text("• \(assertion)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.secondary)
                    Text("C2PA metadata not available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var cameraSection: some View {
        section(title: "Camera") {
            if isLoadingCamera {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Checking for camera metadata...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let camera = item.cameraMetadata, camera.hasAnyData {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.blue)
                    Text("Camera Metadata Present")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .padding(.bottom, 8)

                infoRow("Manufacturer", value: camera.deviceManufacturer)
                infoRow("Model", value: camera.deviceModelName)
                infoRow("Serial Number", value: camera.deviceSerialNumber)
                infoRow("Lens", value: camera.lensModelName)
                infoRow("Time Zone", value: camera.timeZone)
                infoRow("Gamma/Color Profile", value: camera.captureGammaEquation)
                infoRow("Recording Mode", value: camera.recordingModeType)
                infoRow("Capture FPS", value: camera.captureFps)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "camera")
                        .foregroundColor(.secondary)
                    Text("Camera metadata not available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func fetchCameraMetadataIfNeeded() async {
        // Skip if already loaded or loading
        guard item.cameraMetadata == nil, !isLoadingCamera else { return }

        isLoadingCamera = true
        defer { isLoadingCamera = false }

        if let camera = await VideoFileUtils.fetchCameraMetadata(for: item.url) {
            item.cameraMetadata = camera
        }
    }

    private var verificationLinksView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(verificationLinks, id: \.title) { link in
                Link(link.title, destination: link.url)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verificationLinks: [(title: String, url: URL)] {
        [
            ("Content Credentials Verification", URL(string: "https://verify.contentauthenticity.org/")!),
            ("Adobe Content Authenticity Inspector", URL(string: "https://contentauthenticity.adobe.com/inspect")!),
            ("Sony Self Checker", URL(string: "https://digitalsignatureself-checker.authenticity.sony.net")!)
        ]
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formattedSize: String? {
        let bytes = metadata?.sizeBytes ?? item.size
        return VideoMetadataView.byteFormatter.string(fromByteCount: bytes)
    }

    private var formattedCreationDate: String? {
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.creationDateKey]),
              let creationDate = resourceValues.creationDate else {
            return nil
        }
        return VideoMetadataView.dateFormatter.string(from: creationDate)
    }

    private var formattedModificationDate: String? {
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = resourceValues.contentModificationDate else {
            return nil
        }
        return VideoMetadataView.dateFormatter.string(from: modificationDate)
    }

    private func formatBitRate(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 1_000_000 {
            return String(format: "%.2f Mbps", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1f kbps", Double(value) / 1_000)
        } else {
            return "\(value) bps"
        }
    }

    private func formattedFrameRate(_ frameRate: VideoMetadata.FrameRate?) -> String? {
        guard let frameRate else { return nil }
        if let value = frameRate.value {
            return String(format: "%.3f fps", value)
        }
        return frameRate.stringValue
    }

    private func formatSampleRate(_ sampleRate: Int?) -> String? {
        guard let sampleRate else { return nil }
        return VideoMetadataView.numberFormatter.string(from: NSNumber(value: sampleRate))?.appending(" Hz")
    }

    private func formattedScanType(_ stream: VideoMetadata.VideoStream) -> String? {
        guard let isInterlaced = stream.isInterlaced else { return stream.fieldOrder }
        return isInterlaced ? "Interlaced" : "Progressive"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = Locale.current.groupingSeparator
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
