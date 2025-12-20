import SwiftUI

struct MetadataComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [VideoItem]

    private let labelColumnWidth: CGFloat = 140
    private let valueColumnWidth: CGFloat = 200
    private let columnSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerView

            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 24) {
                        fileNamesRow
                        generalSection
                        videoSection
                        audioSection
                    }
                    .padding(.trailing, 24)
                }
            }
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(width: 1400, height: 900)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Metadata Comparison")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("\(items.count) files selected")
                    .font(.headline)
                    .foregroundColor(.secondary)
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
            .accessibilityLabel("Close metadata comparison")
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var fileNamesRow: some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(items, id: \.id) { item in
                VStack(alignment: .leading, spacing: 8) {
                    // Thumbnail
                    if let thumbnailData = item.thumbnailData,
                       let nsImage = NSImage(data: thumbnailData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        // Placeholder for files without thumbnails
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 80)
                            .overlay {
                                Image(systemName: item.hasVideoStream ? "film" : "waveform")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                            }
                    }

                    // Filename
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - General Section

    private var generalSection: some View {
        sectionView(title: "GENERAL") {
            comparisonRow("Container") { item in
                item.metadata?.containerLongName ?? item.metadata?.formatName
            }
            comparisonRow("Duration") { item in
                item.duration
            }
            comparisonRow("File Size") { item in
                formattedSize(for: item)
            }
            comparisonRow("Date Created") { item in
                formattedCreationDate(for: item)
            }
            comparisonRow("Date Modified") { item in
                formattedModificationDate(for: item)
            }
            comparisonRow("Bit Rate") { item in
                formatBitRate(item.metadata?.bitRate)
            }
            comparisonRow("Comment") { item in
                item.metadataComment
            }
        }
    }

    // MARK: - Video Section

    private var videoSection: some View {
        sectionView(title: "VIDEO") {
            comparisonRow("Codec") { item in
                item.metadata?.videoStream?.codecLongName ?? item.metadata?.videoStream?.codec
            }
            comparisonRow("Profile") { item in
                item.metadata?.videoStream?.profile
            }
            comparisonRow("Resolution") { item in
                item.videoResolutionDescription
            }
            comparisonRow("Display Aspect") { item in
                item.metadata?.videoStream?.displayAspectRatio?.stringValue
            }
            comparisonRow("Pixel Aspect") { item in
                item.metadata?.videoStream?.pixelAspectRatio?.stringValue
            }
            comparisonRow("Frame Rate") { item in
                formattedFrameRate(item.metadata?.videoStream?.frameRate)
            }
            comparisonRow("Frame Count") { item in
                item.metadata?.frameCount.map(String.init)
            }
            comparisonRow("Timecode") { item in
                item.metadata?.timecode
            }
            comparisonRow("Bit Depth") { item in
                item.metadata?.videoStream?.bitDepth.map { "\($0)-bit" }
            }
            comparisonRow("Chroma Subsampling") { item in
                item.metadata?.videoStream?.chromaSubsampling
            }
            comparisonRow("Chroma Resolution") { item in
                item.metadata?.videoStream?.chromaResolutionDescription
            }
            comparisonRow("Pixel Format") { item in
                item.metadata?.videoStream?.pixelFormat
            }
            comparisonRow("Alpha Channel") { item in
                item.metadata?.videoStream.map { $0.hasAlpha ? "Yes" : "No" }
            }
            comparisonRow("Color Primaries") { item in
                item.metadata?.videoStream?.colorPrimaries
            }
            comparisonRow("Color Transfer") { item in
                item.metadata?.videoStream?.colorTransfer
            }
            comparisonRow("Color Space") { item in
                item.metadata?.videoStream?.colorSpace
            }
            comparisonRow("Color Range") { item in
                item.metadata?.videoStream?.colorRange
            }
            comparisonRow("Chroma Location") { item in
                item.metadata?.videoStream?.chromaLocation
            }
            comparisonRow("Scan Type") { item in
                formattedScanType(item.metadata?.videoStream)
            }
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        sectionView(title: "AUDIO") {
            // Find max number of audio streams across all items
            let maxStreams = items.compactMap { $0.metadata?.audioStreams.count }.max() ?? 0

            if maxStreams == 0 {
                comparisonRow("") { _ in "No audio stream detected." }
            } else {
                ForEach(0..<maxStreams, id: \.self) { streamIndex in
                    if maxStreams > 1 {
                        streamHeader(streamIndex + 1)
                    }

                    audioStreamRows(streamIndex: streamIndex)
                }
            }
        }
    }

    private func streamHeader(_ streamNumber: Int) -> some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: labelColumnWidth, alignment: .leading)

            ForEach(items, id: \.id) { item in
                let hasStream = (item.metadata?.audioStreams.count ?? 0) >= streamNumber
                Text(hasStream ? "Stream \(streamNumber)" : "—")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .frame(width: valueColumnWidth, alignment: .leading)
            }
        }
        .padding(.top, streamNumber > 1 ? 12 : 0)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func audioStreamRows(streamIndex: Int) -> some View {
        comparisonRow("Codec") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            let stream = streams[streamIndex]
            return stream.codecLongName ?? stream.codec
        }
        comparisonRow("Profile") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].profile
        }
        comparisonRow("Sample Rate") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return formatSampleRate(streams[streamIndex].sampleRate)
        }
        comparisonRow("Channels") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].channels.map(String.init)
        }
        comparisonRow("Channel Layout") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].channelLayout
        }
        comparisonRow("Bit Depth") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return streams[streamIndex].bitDepth.map { "\($0)-bit" }
        }
        comparisonRow("Bit Rate") { item in
            guard let streams = item.metadata?.audioStreams,
                  streamIndex < streams.count else { return nil }
            return formatBitRate(streams[streamIndex].bitRate)
        }
    }

    // MARK: - Layout Helpers

    @ViewBuilder
    private func sectionView<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: columnSpacing) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .frame(width: labelColumnWidth, alignment: .leading)

                // Empty cells for alignment
                ForEach(items, id: \.id) { _ in
                    Text("")
                        .frame(width: valueColumnWidth, alignment: .leading)
                }
            }
            .padding(.bottom, 6)

            content()
        }
    }

    @ViewBuilder
    private func comparisonRow(_ label: String, value: (VideoItem) -> String?) -> some View {
        let values = items.map { value($0) }
        let hasAnyValue = values.contains { $0 != nil && !$0!.isEmpty }

        if hasAnyValue {
            HStack(alignment: .top, spacing: columnSpacing) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: labelColumnWidth, alignment: .leading)

                ForEach(Array(zip(items, values).enumerated()), id: \.element.0.id) { _, itemValuePair in
                    let (_, itemValue) = itemValuePair
                    let displayValue = itemValue ?? "—"

                    Text(displayValue)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(itemValue == nil ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: valueColumnWidth, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(highlightBackground(for: itemValue, in: values))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Highlights values that differ from others
    @ViewBuilder
    private func highlightBackground(for value: String?, in allValues: [String?]) -> some View {
        let uniqueValues = Set(allValues.compactMap { $0 })
        if uniqueValues.count > 1, let value, !value.isEmpty {
            // Multiple different values - highlight to show difference
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.1))
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        }
    }

    // MARK: - Formatters

    private func formattedSize(for item: VideoItem) -> String? {
        let bytes = item.metadata?.sizeBytes ?? item.size
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func formattedCreationDate(for item: VideoItem) -> String? {
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.creationDateKey]),
              let creationDate = resourceValues.creationDate else {
            return nil
        }
        return Self.dateFormatter.string(from: creationDate)
    }

    private func formattedModificationDate(for item: VideoItem) -> String? {
        guard let resourceValues = try? item.url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = resourceValues.contentModificationDate else {
            return nil
        }
        return Self.dateFormatter.string(from: modificationDate)
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
        return Self.numberFormatter.string(from: NSNumber(value: sampleRate))?.appending(" Hz")
    }

    private func formattedScanType(_ stream: VideoMetadata.VideoStream?) -> String? {
        guard let stream else { return nil }
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
