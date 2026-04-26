// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Sheet that lists every site found in a FileZilla `sitemanager.xml` and lets the user pick which
/// ones to import as upload profiles. Returns the selected sites to the caller via `onImport`.
struct FileZillaImportSheet: View {
    let sites: [FileZillaSite]
    let onCancel: () -> Void
    let onImport: ([FileZillaSite]) -> Void

    @State private var selection: Set<UUID>

    init(sites: [FileZillaSite],
         onCancel: @escaping () -> Void,
         onImport: @escaping ([FileZillaSite]) -> Void) {
        self.sites = sites
        self.onCancel = onCancel
        self.onImport = onImport
        // Pre-select everything that is actually importable (skip unsupported/invalid).
        _selection = State(initialValue: Set(sites.filter { $0.status.canImport }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if sites.isEmpty {
                emptyState
            } else {
                siteList
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import FileZilla Sites")
                .font(.headline)
            Text("Select the sites to import as upload profiles. Encrypted passwords are not imported — you'll need to enter them again after import.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
    }

    private var siteList: some View {
        List {
            ForEach(sites) { site in
                row(for: site)
            }
        }
        .listStyle(.bordered)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No sites found in this file.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Select Importable") { selectAllImportable() }
                .disabled(sites.allSatisfy { !$0.status.canImport })

            Button("Deselect All") { selection.removeAll() }
                .disabled(selection.isEmpty)

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)

            Button("Import \(selection.count)") {
                let selected = sites.filter { selection.contains($0.id) }
                onImport(selected)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for site: FileZillaSite) -> some View {
        let isSelectable = site.status.canImport

        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: bindingForSelection(of: site))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!isSelectable)

            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .fontWeight(.medium)
                Text(siteSubtitle(site))
                    .font(.caption)
                    .foregroundColor(.secondary)
                statusBadge(for: site.status)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(isSelectable ? 1.0 : 0.6)
    }

    private func siteSubtitle(_ site: FileZillaSite) -> String {
        let backendName = site.useFTPS ? "FTPS" : site.suggestedBackend.displayName
        let portFragment: String = {
            if let port = site.port { return ":\(port)" }
            return ""
        }()
        let userFragment = site.username.isEmpty ? "" : "  •  \(site.username)"
        let host = site.host.isEmpty ? "(no host)" : site.host
        return "\(backendName)  •  \(host)\(portFragment)\(userFragment)"
    }

    @ViewBuilder
    private func statusBadge(for status: FileZillaImportStatus) -> some View {
        switch status {
        case .importable:
            EmptyView()
        case .passwordEncrypted:
            badge("Password encrypted — re-enter after import", color: .orange, icon: "lock.fill")
        case .passwordRequired:
            badge("Password not stored — re-enter after import", color: .orange, icon: "key.fill")
        case .unsupportedProtocol(let name):
            badge("Unsupported protocol: \(name)", color: .red, icon: "xmark.circle.fill")
        case .invalid(let reason):
            badge("Skipped — \(reason)", color: .red, icon: "exclamationmark.triangle.fill")
        }
    }

    private func badge(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundColor(color)
    }

    // MARK: - Bindings & actions

    private func bindingForSelection(of site: FileZillaSite) -> Binding<Bool> {
        Binding(
            get: { selection.contains(site.id) },
            set: { isOn in
                if isOn { selection.insert(site.id) } else { selection.remove(site.id) }
            }
        )
    }

    private func selectAllImportable() {
        selection = Set(sites.filter { $0.status.canImport }.map(\.id))
    }
}
