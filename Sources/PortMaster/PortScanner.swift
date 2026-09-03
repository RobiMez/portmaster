import AppKit
import Combine

struct ListeningPort: Identifiable, Equatable {
    let port: Int
    let pid: Int32
    let command: String
    let uid: uid_t           // process owner, from lsof
    let addresses: [String]
    var repoName: String? = nil      // git root directory name, when the process runs in a repo
    var gitBranch: String? = nil     // current branch of that repo
    var isContainer: Bool = false    // published by a container runtime (Docker/OrbStack)
    var containerRuntime: String? = nil  // "Docker" or "OrbStack"
    var containerProject: String? = nil  // compose project, or container name
    var containerService: String? = nil  // compose service (nil when standalone)
    var isDevServer: Bool = false    // stamped once per scan, after enrichment

    var id: String { "\(pid):\(port)" }

    /// The app/command name (independent of any repo it runs in).
    var processName: String {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return command
    }

    /// Container project when published by a runtime, else repo name, else the
    /// app/command name.
    var displayName: String {
        if let containerProject, !containerProject.isEmpty { return containerProject }
        if let repoName, !repoName.isEmpty { return repoName }
        return processName
    }

    var addressSummary: String {
        addresses.joined(separator: "  ")
    }

    /// Matches the lsof command name (full, from `+c 0`) against common dev
    /// runtimes / task-runners. Case-insensitive, prefix-based so versioned
    /// names like `python3.11` and `node-18` still match.
    static func isDevRuntime(_ command: String) -> Bool {
        let base = command.lowercased()
        return devRuntimePrefixes.contains { base.hasPrefix($0) }
    }

    // Linear prefix scan, so a plain Array — a Set buys nothing here.
    private static let devRuntimePrefixes: [String] = [
        "node", "deno", "bun", "ts-node", "tsx", "nodemon",
        "python", "flask", "gunicorn", "uvicorn", "hypercorn",
        "ruby", "rails", "puma", "rackup", "unicorn",
        "php", "php-fpm",
        "java", "gradle", "mvn",
        "dotnet",
        "cargo", "air",
        "go", "hugo",
        "elixir", "mix", "beam", "phoenix",
        "vite", "next", "webpack", "esbuild", "rollup", "parcel", "ng",
        "jekyll", "meteor", "expo", "rustc",
    ]
}

/// Clusters ports that share an owner (their `displayName`: container project →
/// repo → app name), preserving the incoming sort order by first appearance.
/// Most groups have a single element; multi-element groups are the apps that
/// listen on several ports (e.g. Spotify, OrbStack).
func groupPortsByOwner(_ ports: [ListeningPort]) -> [[ListeningPort]] {
    var order: [String] = []
    var buckets: [String: [ListeningPort]] = [:]
    for port in ports {
        let key = port.displayName
        if buckets[key] == nil { order.append(key) }
        buckets[key, default: []].append(port)
    }
    return order.map { buckets[$0]! }
}

struct ProcessUsage: Equatable {
    let cpuPercent: Double
    let memoryBytes: UInt64
}

enum KillState: Equatable {
    case terminating(since: Date)
    case failed(String)

    var isStuck: Bool {
        if case .terminating(let since) = self {
            return Date().timeIntervalSince(since) > 3
        }
        return false
    }
}

final class PortScanner: ObservableObject {
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var killStates: [String: KillState] = [:]
    @Published private(set) var iconCache: [Int32: NSImage] = [:]
    @Published private(set) var usage: [Int32: ProcessUsage] = [:]

    private var timer: Timer?
    private var isActive = false
    private var activeInterval: TimeInterval = 2
    private var idleInterval: TimeInterval = 15
    private var interval: TimeInterval = 15
    private let queue = DispatchQueue(label: "portmaster.scan", qos: .userInitiated)
    private var isScanning = false

    // Git resolution caches — only ever touched on `queue`, so no locking needed.
    private var gitRootCache: [String: URL?] = [:]                    // cwd -> git root (nil = not a repo)
    private var branchCache: [String: (branch: String, at: Date)] = [:]  // rootPath -> branch + fetch time
    private static let branchTTL: TimeInterval = 30

    // Container resolution caches — also queue-confined.
    private var dockerPathResolved = false        // whether we've looked for the docker CLI yet
    private var dockerPath: String?               // cached docker executable path (nil = not installed)
    private var containerCache: (map: [Int: ContainerInfo], at: Date)?
    private static let containerTTL: TimeInterval = 5

    func start() {
        scanNow()
        reschedule()
    }

    func setActive(_ active: Bool) {
        isActive = active
        applyInterval(scanImmediately: active)
    }

    /// Called when the user changes scan-frequency settings; re-arms the live timer.
    func updateIntervals(active: TimeInterval, idle: TimeInterval) {
        activeInterval = active
        idleInterval = idle
        applyInterval(scanImmediately: false)
    }

    private func applyInterval(scanImmediately: Bool) {
        let newInterval = isActive ? activeInterval : idleInterval
        if newInterval != interval {
            interval = newInterval
            reschedule()
        }
        if scanImmediately { scanNow() }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanNow()
        }
        timer?.tolerance = interval * 0.2
    }

    func scanNow() {
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            guard let self else { return }
            var result = Self.runLsof()
            let usage = Self.runPs(pids: Set(result.map(\.pid)))
            result = self.enrichWithGit(result)
            result = self.enrichWithContainers(result)
            result = Self.classifyDevServers(result)
            DispatchQueue.main.async {
                self.isScanning = false
                self.publish(result, usage: usage)
            }
        }
    }

    private func publish(_ scanned: [ListeningPort], usage newUsage: [Int32: ProcessUsage]) {
        let sorted = scanned.sorted { lhs, rhs in
            if lhs.isDevServer != rhs.isDevServer { return lhs.isDevServer }
            return (lhs.port, lhs.pid) < (rhs.port, rhs.pid)
        }
        if sorted != ports { ports = sorted }

        // Drop kill bookkeeping for rows that no longer exist.
        let liveIDs = Set(sorted.map(\.id))
        killStates = killStates.filter { liveIDs.contains($0.key) }

        var icons = iconCache
        let livePIDs = Set(sorted.map(\.pid))
        icons = icons.filter { livePIDs.contains($0.key) }
        for pid in livePIDs where icons[pid] == nil {
            if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
                icon.size = NSSize(width: 32, height: 32)
                icons[pid] = icon
            }
        }
        if icons != iconCache { iconCache = icons }
        if newUsage != usage { usage = newUsage }
    }

    // MARK: - Killing

    func kill(_ entry: ListeningPort, force: Bool) {
        let sig = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid_t(entry.pid), sig) == 0 {
            killStates[entry.id] = .terminating(since: Date())
        } else {
            let message = errno == EPERM
                ? "No permission (owned by another user)"
                : String(cString: strerror(errno))
            killStates[entry.id] = .failed(message)
        }
        // Re-scan shortly after so the row disappears (or reports back) quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scanNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scanNow() }
    }

    // MARK: - Dev classification

    /// Stamps `isDevServer` once per scan — a container, or a process the
    /// current user owns that runs inside a git repo or a known dev runtime.
    /// The ownership gate keeps root/_system daemons (e.g. a system `java`)
    /// out of the dev group even when their command matches a runtime prefix.
    /// Must run after git/container enrichment; the sort and every view
    /// re-render then read a stored flag instead of re-matching.
    private static func classifyDevServers(_ ports: [ListeningPort]) -> [ListeningPort] {
        let currentUser = getuid()
        return ports.map { port in
            var classified = port
            classified.isDevServer = port.isContainer
                || (port.uid == currentUser
                    && (port.repoName != nil || ListeningPort.isDevRuntime(port.command)))
            return classified
        }
    }

    // MARK: - Git

    /// Fills in `repoName`/`gitBranch` for any port whose process runs inside a git repo.
    /// Runs on `queue`; safe to touch the caches here.
    private func enrichWithGit(_ ports: [ListeningPort]) -> [ListeningPort] {
        guard !ports.isEmpty else { return ports }

        let cwds = Self.resolveCWDs(pids: Set(ports.map(\.pid)))

        // Resolve a git root per distinct cwd (cached indefinitely — a dir's repo
        // membership doesn't change), then a branch per distinct root (cached ~30s).
        var rootForCWD: [String: URL] = [:]
        var branchForRoot: [String: String] = [:]

        for cwd in Set(cwds.values) {
            let root: URL?
            if let cached = gitRootCache[cwd] {
                root = cached
            } else {
                root = Self.findGitRoot(from: cwd)
                gitRootCache[cwd] = root
            }
            guard let root else { continue }
            rootForCWD[cwd] = root

            let rootPath = root.path
            if branchForRoot[rootPath] != nil { continue }
            if let entry = branchCache[rootPath],
               Date().timeIntervalSince(entry.at) < Self.branchTTL {
                branchForRoot[rootPath] = entry.branch
            } else if let branch = Self.gitBranch(at: rootPath) {
                branchForRoot[rootPath] = branch
                branchCache[rootPath] = (branch, Date())
            }
        }

        // Prune caches for cwds/roots that are no longer live.
        let liveCWDs = Set(cwds.values)
        gitRootCache = gitRootCache.filter { liveCWDs.contains($0.key) }
        let liveRoots = Set(rootForCWD.values.map(\.path))
        branchCache = branchCache.filter { liveRoots.contains($0.key) }

        return ports.map { port in
            guard let cwd = cwds[port.pid], let root = rootForCWD[cwd] else { return port }
            var enriched = port
            enriched.repoName = root.lastPathComponent
            enriched.gitBranch = branchForRoot[root.path]
            return enriched
        }
    }

    /// Maps pids to their current working directory via `lsof -a -p <pids> -d cwd -Fn`.
    private static func resolveCWDs(pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fn"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return [:] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                currentPID = Int32(value)
            case "n":
                if let pid = currentPID, value.hasPrefix("/") { result[pid] = value }
            default:
                break
            }
        }
        return result
    }

    /// Walks up from `path` looking for a `.git` entry. No shell invocation.
    private static func findGitRoot(from path: String) -> URL? {
        var current = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Current branch via `git -C <root> rev-parse --abbrev-ref HEAD`.
    /// Returns nil on failure or detached HEAD.
    private static func gitBranch(at rootPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootPath, "rev-parse", "--abbrev-ref", "HEAD"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let branch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch.isEmpty || branch == "HEAD") ? nil : branch
    }

    // MARK: - Containers

    struct ContainerInfo {
        let project: String   // compose project, or container name if standalone
        let service: String   // compose service (empty for standalone containers)
    }

    /// Flags container-runtime ports and labels them with their compose
    /// project/service via `docker ps`. Runs on `queue`.
    private func enrichWithContainers(_ ports: [ListeningPort]) -> [ListeningPort] {
        // Which rows are owned by a container runtime (Docker/OrbStack)?
        let runtimePorts = ports.filter { Self.containerRuntimeName(for: $0.command) != nil }
        guard !runtimePorts.isEmpty else { return ports }

        let containers = resolveContainers()

        return ports.map { port in
            guard let runtime = Self.containerRuntimeName(for: port.command) else { return port }
            var enriched = port
            enriched.isContainer = true
            enriched.containerRuntime = runtime
            if let info = containers[port.port] {
                enriched.containerProject = info.project
                enriched.containerService = info.service.isEmpty ? nil : info.service
            } else {
                // Daemon unreachable or port not mapped — still mark it as a
                // container with the generic runtime label.
                enriched.containerProject = runtime
            }
            return enriched
        }
    }

    /// Container map keyed by host port, cached for a few seconds so the 2s
    /// expanded scan doesn't shell out to docker on every tick.
    private func resolveContainers() -> [Int: ContainerInfo] {
        if let cache = containerCache,
           Date().timeIntervalSince(cache.at) < Self.containerTTL {
            return cache.map
        }

        if !dockerPathResolved {
            dockerPath = Self.dockerExecutable()
            dockerPathResolved = true
        }
        guard let docker = dockerPath else {
            containerCache = ([:], Date())
            return [:]
        }

        let map = Self.runDockerPS(docker: docker).map(Self.parseContainerOutput) ?? [:]
        containerCache = (map, Date())
        return map
    }

    /// First existing docker CLI among the common Docker Desktop / OrbStack paths.
    private static func dockerExecutable() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs `docker ps` with a hard timeout; nil on launch failure or timeout.
    private static func runDockerPS(docker: String) -> String? {
        let format = #"{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["ps", "--no-trunc", "--format", format]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        // `docker ps` can hang if the daemon is starting; bound the wait.
        if done.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses tab-separated `docker ps` rows into a host-port -> ContainerInfo map.
    static func parseContainerOutput(_ output: String) -> [Int: ContainerInfo] {
        var result: [Int: ContainerInfo] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let name = cols[0].trimmingCharacters(in: .whitespaces)
            let portsField = cols[1]
            let project = cols.count > 2 ? cols[2].trimmingCharacters(in: .whitespaces) : ""
            let service = cols.count > 3 ? cols[3].trimmingCharacters(in: .whitespaces) : ""
            let info = ContainerInfo(project: project.isEmpty ? name : project, service: service)
            for port in parseContainerHostPorts(portsField) {
                result[port] = info
            }
        }
        return result
    }

    /// Extracts published host ports from a docker Ports field, e.g.
    /// `0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp` -> [3000]. Unpublished
    /// ports (`8000/tcp` with no `->`) are ignored.
    static func parseContainerHostPorts(_ portsField: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for match in portsField.matches(of: #/:(\d{1,5})->/#) {
            guard let port = Int(match.1), seen.insert(port).inserted else { continue }
            ports.append(port)
        }
        return ports
    }

    /// Maps a listening process's command to its container runtime, or nil.
    /// lsof runs with `+c 0`, so names are full (e.g. `OrbStack Helper`,
    /// `com.docker.backend`, `docker-proxy`, `vpnkit-bridge`).
    static func containerRuntimeName(for command: String) -> String? {
        let lower = command.lowercased()
        if lower.contains("orbstack") { return "OrbStack" }
        if lower.contains("docker") || lower.hasPrefix("com.dock") || lower.hasPrefix("vpnkit") {
            return "Docker"
        }
        return nil
    }

    // MARK: - ps

    /// Fetches CPU% and resident memory for the given pids.
    /// `%cpu` is ps's decaying average; `rss` is reported in 1024-byte units.
    private static func runPs(pids: Set<Int32>) -> [Int32: ProcessUsage] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-o", "pid=,%cpu=,rss=",
            "-p", pids.map(String.init).joined(separator: ","),
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return [:] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var usage: [Int32: ProcessUsage] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            usage[pid] = ProcessUsage(cpuPercent: cpu, memoryBytes: rssKB * 1024)
        }
        return usage
    }

    // MARK: - lsof

    /// Parses `lsof +c 0 -iTCP -sTCP:LISTEN -P -n -Fpcun` machine-readable output.
    private static func runLsof() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+c", "0", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-Fpcun"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [String: ListeningPort] = [:]
        var pid: Int32 = 0
        var command = "?"
        var uid: uid_t = 0

        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
            case "c":
                command = value
            case "u":
                uid = uid_t(value) ?? 0
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                var address = String(value[..<colon])
                if address == "*" { address = "*" }
                let key = "\(pid):\(port)"
                if let existing = results[key] {
                    if !existing.addresses.contains(address) {
                        results[key] = ListeningPort(
                            port: port, pid: pid, command: command, uid: uid,
                            addresses: existing.addresses + [address]
                        )
                    }
                } else {
                    results[key] = ListeningPort(
                        port: port, pid: pid, command: command, uid: uid, addresses: [address]
                    )
                }
            default:
                break
            }
        }
        return Array(results.values)
    }
}
