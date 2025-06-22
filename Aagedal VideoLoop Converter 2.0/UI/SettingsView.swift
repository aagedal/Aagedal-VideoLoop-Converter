import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    
    var body: some View {
        Form {
            // App Info Section
            Section {
                Text("About").font(.headline)
                HStack {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Aagedal VideoLoop Converter")
                            .font(.headline)
                        
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                            Text("Version \(version) (\(build))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 8)
                
                Text("A simple tool to convert videos into seamless loops.")
                    .font(.body)
                    .padding(.bottom, 8)
                
                Divider()
                
                // Output Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Output Folder:")
                        .font(.headline)
                    
                    HStack {
                        Text(outputFolder)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(outputFolder)
                        
                        Button(action: {
                            let url = URL(fileURLWithPath: outputFolder)
                            guard FileManager.default.fileExists(atPath: url.path) else {
                                // If the saved folder doesn't exist, reset to default
                                outputFolder = AppConstants.defaultOutputDirectory.path
                                NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultOutputDirectory])
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Links Section
            Section {
                HStack {
                    Spacer()
                    Link("Visit Developer Website", destination: URL(string: "https://aagedal.me")!)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 400)
        .padding()
    }
}

#Preview {
    SettingsView()
}
