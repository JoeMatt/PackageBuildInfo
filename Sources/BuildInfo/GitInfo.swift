import Foundation

final class GitInfoCoder {
    private let git: URL
    private let gitDirectory: URL
    private let outputFile: URL?

    private struct GitInfo {
        var isDirty = true
        var date = ""
        var count = "nil"
        var branch = "nil"
        var tag = "nil"
        var digest: String?
    }

    init?(gitDirectory: URL, outputFile: URL?) {
        self.gitDirectory = gitDirectory
        self.outputFile = outputFile
        guard let git = GitInfoCoder.searchGit() else {
            print("Git not found in PATH")
            return nil
        }
        self.git = git
    }

    private static func searchGit() -> URL? {
        let pathList = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"

        for path in pathList.split(separator: ":") {
            let gitURL = URL(fileURLWithPath: String(path)).appendingPathComponent("git")
            if let res = try? gitURL.resourceValues(forKeys: [.isExecutableKey]),
               res.isExecutable ?? false
            {
                return gitURL
            }
        }
        return nil
    }

    private func runGit(command: String) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = git
        process.currentDirectoryURL = gitDirectory

        let stdinPipe = Pipe()
        let stdErrPipe = Pipe()
        process.standardOutput = stdinPipe
        process.standardError = stdErrPipe
        process.arguments = command.split(separator: " ").map { String($0) }
        try process.run()
        process.waitUntilExit()
        let status = process.terminationStatus

        let data = try stdinPipe.fileHandleForReading.readToEnd() ?? Data()
        let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (exitCode: status, output: output)
    }

    private func getInfo() throws -> GitInfo {
        var info = GitInfo()

        var (exitCode, output) = try runGit(command: "status --porcelain -uno")
        guard exitCode == 0, output.isEmpty else {
            info.date = "\(Date().timeIntervalSince1970)"
            return info
        }
        info.isDirty = false
        (exitCode, output) = try runGit(command: "describe --exact-match --tags")
        if exitCode == 0, !output.isEmpty {
            info.tag = "\"\(output)\""
        }
        (exitCode, output) = try runGit(command: "branch --show-current")
        if exitCode == 0, !output.isEmpty {
            info.branch = "\"\(output)\""
        }
        (exitCode, output) = try runGit(command: "show -s --format=%H:%ct")
        if exitCode == 0, !output.isEmpty {
            let parts = output.split(separator: ":").map { String($0) }
            info.digest = parts[0]
            info.date = parts[1]
        }
        (exitCode, output) = try runGit(command: "rev-list --count HEAD")
        if exitCode == 0, !output.isEmpty {
            info.count = output
        }
        return info
    }
    
    private func generateCode(_ info: GitInfo) -> String {
        let timeZone = TimeZone.current.secondsFromGMT()

        var digestS = "["
        if var digest = info.digest {
            for _ in 0..<digest.count / 2 {
                digestS += "0x" + digest.prefix(2) + ", "
                digest.removeFirst(2)
            }
            digestS.removeLast(2)
        }
        digestS += "]"

        let code = """
        //
        // Build info
        //
        import Foundation

        public struct BuildInfo {
            let timeStamp: Date     // Time of dirty build
            let timeZone: TimeZone  // Time Zone of dirty build
            let isDirty: Bool       // Dirty build - git directory is't clean. In this case only timeStamp available
            let count: Int?         // Commit count
            let tag: String?        // Tag, if exist
            let branch: String?     // Git branch name
            let digest: [UInt8]     // Commit sha1 digest (20 bytes)

            var commit: String {
                digest.reduce("") { $0 + String(format: "%02x", $1) }
            }
        }
        let buildInfo = BuildInfo(timeStamp: Date(timeIntervalSince1970: \(info.date)),
                                  timeZone: TimeZone(secondsFromGMT: \(timeZone))!,
                                  isDirty: \(info.isDirty ? "true" : "false"),
                                  count: \(info.count),
                                  tag: \(info.tag),
                                  branch: \(info.branch),
                                  digest: \(digestS))
        """
        return code
    }
    
    func codegen() {
        do {
            let info = try getInfo()
            let code = generateCode(info)
            if let outputFile = outputFile {
                try code.write(to: outputFile, atomically: true, encoding: .utf8)
            } else {
                print(code)
            }
        } catch  {
            print(error.localizedDescription)
            exit(1)
        }
    }
}
