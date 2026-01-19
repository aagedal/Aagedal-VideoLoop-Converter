// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolves paths to external binaries (ffmpeg, ffprobe, yt-dlp)
/// Priority: 1) Custom path from settings, 2) Bundled in app
enum BinaryPathResolver {

    // MARK: - FFmpeg

    /// Resolves the path to ffmpeg binary
    /// Priority: custom path > bundled
    static var ffmpegPath: String? {
        // Check custom path first
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // Fall back to bundled
        return Bundle.main.path(forResource: "ffmpeg", ofType: nil)
    }

    // MARK: - FFprobe

    /// Resolves the path to ffprobe binary
    /// Priority: custom path > bundled
    static var ffprobePath: String? {
        // Check custom path first
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFprobePathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // Fall back to bundled
        return Bundle.main.path(forResource: "ffprobe", ofType: nil)
    }

    // MARK: - BMX Tools (MXF handling)

    /// Resolves the path to bmxtranswrap binary (MXF transcoding)
    static var bmxtranswrapPath: String? {
        Bundle.main.path(forResource: "bmxtranswrap", ofType: nil)
    }

    /// Resolves the path to mxf2raw binary (MXF extraction/analysis)
    static var mxf2rawPath: String? {
        Bundle.main.path(forResource: "mxf2raw", ofType: nil)
    }

    // MARK: - ExifTool

    /// Resolves the path to exiftool binary
    /// Priority: custom path > downloaded > system (Homebrew)
    static var exiftoolPath: String? {
        // Check custom path first
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.exiftoolCustomPathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // Check downloaded version in tools directory
        let downloadedPath = AppConstants.ytdlpToolsDirectory
            .appendingPathComponent("exiftool").path
        if FileManager.default.isExecutableFile(atPath: downloadedPath) {
            return downloadedPath
        }

        // Check system locations (Homebrew)
        let systemPaths = [
            "/opt/homebrew/bin/exiftool"
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Returns whether a custom exiftool path is configured
    static var isUsingCustomExiftool: Bool {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.exiftoolCustomPathKey),
              !customPath.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: customPath)
    }

    // MARK: - Version Info

    /// Gets the version of a binary by running it with --version
    static func getVersion(at path: String) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Extract first line which typically contains version info
                let firstLine = output.components(separatedBy: .newlines).first ?? ""
                return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Gets ffmpeg version string
    static func getFFmpegVersion() async -> String? {
        guard let path = ffmpegPath else { return nil }
        return await getVersion(at: path)
    }

    /// Gets ffprobe version string
    static func getFFprobeVersion() async -> String? {
        guard let path = ffprobePath else { return nil }
        return await getVersion(at: path)
    }

    // MARK: - Path Info

    /// Returns whether a custom ffmpeg path is configured
    static var isUsingCustomFFmpeg: Bool {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey),
              !customPath.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: customPath)
    }

    /// Returns whether a custom ffprobe path is configured
    static var isUsingCustomFFprobe: Bool {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFprobePathKey),
              !customPath.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: customPath)
    }

    /// Saves a custom ffmpeg path
    static func saveCustomFFmpegPath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.customFFmpegPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.customFFmpegPathKey)
        }
    }

    /// Saves a custom ffprobe path
    static func saveCustomFFprobePath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.customFFprobePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.customFFprobePathKey)
        }
    }
}

// MARK: - Homebrew Python Script Executor

/// Helper to detect and execute Homebrew Python scripts (like yt-dlp) properly
/// Homebrew installs Python tools with venv interpreters that may be blocked by Hardened Runtime.
/// This helper detects such scripts and executes them using the main Homebrew Python instead.
enum HomebrewPythonExecutor {
    private static let commonPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin"
    ]

    private static func mergedPath(from entries: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(trimmed) {
                result.append(trimmed)
                seen.insert(trimmed)
            }
        }
        return result.joined(separator: ":")
    }

    /// Execution info for a Homebrew Python script
    struct ExecutionInfo {
        let pythonPath: String      // The venv Python from shebang
        let mainPythonPath: String  // Main Homebrew Python to use
        let sitePackages: String    // PYTHONPATH to set
    }

    /// Checks if a script is a Homebrew Python script and returns execution info
    static func executionInfo(for scriptPath: String) -> ExecutionInfo? {
        // Read the shebang line - resolve symlinks first
        let resolvedPath = (scriptPath as NSString).resolvingSymlinksInPath

        guard let data = FileManager.default.contents(atPath: resolvedPath),
              let content = String(data: data, encoding: .utf8) else {
            print("[HomebrewPythonExecutor] Failed to read file at: \(resolvedPath)")
            return nil
        }

        let firstLine = content.components(separatedBy: .newlines).first ?? ""
        print("[HomebrewPythonExecutor] First line: \(firstLine)")

        // Check if it's a Homebrew Cellar Python shebang
        // e.g., #!/opt/homebrew/Cellar/yt-dlp/2025.12.8/libexec/bin/python
        guard firstLine.hasPrefix("#!"),
              firstLine.contains("/opt/homebrew/Cellar/") else {
            print("[HomebrewPythonExecutor] Not a Homebrew Python script")
            return nil
        }

        // Extract the Cellar path (e.g., /opt/homebrew/Cellar/yt-dlp/2025.12.8)
        let shebangPath = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        print("[HomebrewPythonExecutor] Shebang path: \(shebangPath)")

        // Find the libexec part and extract the base Cellar path
        guard let libexecRange = shebangPath.range(of: "/libexec/") else {
            print("[HomebrewPythonExecutor] No /libexec/ found in shebang")
            return nil
        }

        let cellarBasePath = String(shebangPath[..<libexecRange.lowerBound])
        print("[HomebrewPythonExecutor] Cellar base: \(cellarBasePath)")

        // Find Python version by trying common versions
        // (Can't list directory due to Hardened Runtime restrictions)
        let libPath = cellarBasePath + "/libexec/lib"
        print("[HomebrewPythonExecutor] Lib path: \(libPath)")

        // Try common Python versions in order (newest first)
        let pythonVersions = ["3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]
        var foundVersion: String?
        var sitePackages: String?

        for version in pythonVersions {
            let testPath = "\(libPath)/python\(version)/site-packages"
            if FileManager.default.fileExists(atPath: testPath) {
                foundVersion = version
                sitePackages = testPath
                print("[HomebrewPythonExecutor] Found Python \(version) at: \(testPath)")
                break
            }
        }

        guard let pythonVersion = foundVersion, let packages = sitePackages else {
            print("[HomebrewPythonExecutor] No Python site-packages found for versions: \(pythonVersions)")
            return nil
        }

        // Use main Homebrew Python with matching version
        let python3Path = "/opt/homebrew/bin/python\(pythonVersion)"

        // Fallback to generic python3 if specific version not found
        let finalPythonPath = FileManager.default.fileExists(atPath: python3Path)
            ? python3Path
            : "/opt/homebrew/bin/python3"

        let finalSitePackages = packages

        print("[HomebrewPythonExecutor] Success! Python: \(finalPythonPath), PYTHONPATH: \(finalSitePackages)")
        return ExecutionInfo(
            pythonPath: shebangPath,
            mainPythonPath: finalPythonPath,
            sitePackages: finalSitePackages
        )
    }

    /// Checks if a file is a Mach-O binary (standalone executable) vs a script
    static func isStandaloneBinary(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              data.count >= 4 else {
            return false
        }

        // Check for Mach-O magic numbers
        let magic = data.prefix(4)
        let machO64 = Data([0xCF, 0xFA, 0xED, 0xFE])  // 64-bit Mach-O
        let machO32 = Data([0xCE, 0xFA, 0xED, 0xFE])  // 32-bit Mach-O
        let fatBinary = Data([0xCA, 0xFE, 0xBA, 0xBE]) // Universal binary

        return magic == machO64 || magic == machO32 || magic == fatBinary
    }

    /// Configures a Process to execute yt-dlp
    /// Handles both standalone binaries (yt-dlp_macos) and Python scripts (Homebrew)
    static func configureProcess(_ process: Process, scriptPath: String, arguments: [String]) {
        // Check if it's a standalone binary (like yt-dlp_macos from GitHub)
        if isStandaloneBinary(at: scriptPath) {
            print("[HomebrewPythonExecutor] Using standalone binary: \(scriptPath)")
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = arguments

            // Add bundled ffmpeg to PATH so yt-dlp can find it for post-processing
            var env = ProcessInfo.processInfo.environment
            var pathEntries: [String] = []
            if let ffmpegPath = BinaryPathResolver.ffmpegPath {
                let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
                pathEntries.append(ffmpegDir)
                print("[HomebrewPythonExecutor] Added ffmpeg to PATH: \(ffmpegDir)")
            }
            pathEntries.append(contentsOf: commonPathEntries)
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            process.environment = env
            return
        }

        // It's a Python script - try Homebrew detection with PYTHONPATH
        if let info = executionInfo(for: scriptPath) {
            // Try various system Pythons
            let cltPython = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"
            let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"

            let pythonPath: String
            if FileManager.default.fileExists(atPath: cltPython) {
                pythonPath = cltPython
            } else if FileManager.default.fileExists(atPath: xcodePython) {
                pythonPath = xcodePython
            } else {
                pythonPath = "/usr/bin/python3"
            }

            print("[HomebrewPythonExecutor] Using \(pythonPath) with PYTHONPATH: \(info.sitePackages)")
            process.executableURL = URL(fileURLWithPath: pythonPath)
            // Use -u for unbuffered stdout/stderr to ensure real-time progress output
            process.arguments = ["-u", "-m", "yt_dlp"] + arguments
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = info.sitePackages
            var pathEntries = commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            process.environment = env
        } else {
            // Last resort - try executing directly (may work for scripts with valid shebangs)
            print("[HomebrewPythonExecutor] Executing directly: \(scriptPath)")
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            var pathEntries = commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            process.environment = env
        }
    }
}
