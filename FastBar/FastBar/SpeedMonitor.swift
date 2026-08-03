//
//  SpeedMonitor.swift
//  FastBar
//

import Foundation
import Combine
import WebKit

enum SpeedSource: String, Codable, Sendable, CaseIterable {
    case fastDotCom = "Fast.com"
    case fastProbeFallback = "FAST probe fallback"
    case cloudflareFallback = "Cloudflare fallback"

    /// Fallback probes download a fixed, much smaller payload than Fast.com's
    /// adaptive test, so their results are not comparable and are kept out of
    /// the rolling average.
    var isFallback: Bool {
        self != .fastDotCom
    }

    /// A stored history may contain a source string this version no longer
    /// produces. Decode it as `.fastDotCom` instead of failing, because
    /// `loadHistory()` discards the entire file when decoding throws.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpeedSource(rawValue: raw) ?? .fastDotCom
    }
}

struct SpeedSample: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let downloadMbps: Double
    let source: SpeedSource
    let bytesDownloaded: Int
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        downloadMbps: Double,
        source: SpeedSource,
        bytesDownloaded: Int,
        duration: TimeInterval
    ) {
        self.id = id
        self.timestamp = timestamp
        self.downloadMbps = downloadMbps
        self.source = source
        self.bytesDownloaded = bytesDownloaded
        self.duration = duration
    }
}

@MainActor
final class SpeedMonitor: ObservableObject {
    @Published private(set) var samples: [SpeedSample] = []
    @Published private(set) var isTesting = false
    @Published private(set) var lastError: String?
    @Published var checkIntervalMinutes: Int {
        didSet {
            guard checkIntervalMinutes != oldValue else { return }
            UserDefaults.standard.set(checkIntervalMinutes, forKey: Self.intervalPreferenceKey)

            if monitoringTask != nil {
                startMonitoring(runImmediately: false)
            }
        }
    }

    let availableIntervals = [1, 5, 10, 15, 30, 60]

    private static let intervalPreferenceKey = "checkIntervalMinutes"
    private var monitoringTask: Task<Void, Never>?

    init(startAutomatically: Bool = true) {
        let savedInterval = UserDefaults.standard.integer(forKey: Self.intervalPreferenceKey)
        checkIntervalMinutes = [1, 5, 10, 15, 30, 60].contains(savedInterval)
            ? savedInterval
            : 10
        loadHistory()
        if startAutomatically {
            startMonitoring()
        }
    }

    deinit {
        monitoringTask?.cancel()
    }

    var latestSample: SpeedSample? { samples.last }

    var menuBarCurrentText: String {
        if isTesting && latestSample == nil {
            return "Testing…"
        }

        guard let latest = latestSample?.downloadMbps else {
            return "— Mbps"
        }

        let latestText = latest.formatted(
            .number.precision(.fractionLength(latest >= 100 ? 0 : 1))
        )

        return "\(latestText) Mbps"
    }

    var menuBarAverageText: String {
        guard let average = threeHourAverage else {
            return "3h avg —"
        }
        let averageText = average.formatted(
            .number.precision(.fractionLength(average >= 100 ? 0 : 1))
        )
        return "3h avg \(averageText) Mbps"
    }

    var last24Hours: [SpeedSample] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return samples.filter { $0.timestamp >= cutoff }
    }

    var threeHourSamples: [SpeedSample] {
        let cutoff = Date().addingTimeInterval(-3 * 60 * 60)
        return samples.filter { $0.timestamp >= cutoff && !$0.source.isFallback }
    }

    var threeHourAverage: Double? {
        let recent = threeHourSamples
        guard !recent.isEmpty else { return nil }
        return recent.map(\.downloadMbps).reduce(0, +) / Double(recent.count)
    }

    var recentSamples: [SpeedSample] {
        Array(samples.suffix(5).reversed())
    }

    func refresh() async {
        guard !isTesting else { return }

        isTesting = true
        defer { isTesting = false }

        do {
            let sample = try await FastSpeedTest.measure(bytesPerStream: probeBytesPerStream)
            samples.append(sample)
            trimHistory()
            lastError = nil
            saveHistory()
        } catch is CancellationError {
            // Changing the interval or quitting cancels the run in progress.
            // That is not a measurement failure, so leave `lastError` alone.
        } catch {
            lastError = "Speed test failed: \(error.localizedDescription)"
        }
    }

    private var probeBytesPerStream: Int {
        switch checkIntervalMinutes {
        case 1:
            return 2 * 1_024 * 1_024
        case 5:
            return 4 * 1_024 * 1_024
        default:
            return 8 * 1_024 * 1_024
        }
    }

    private func startMonitoring(runImmediately: Bool = true) {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }

            if runImmediately {
                await refresh()
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(checkIntervalMinutes * 60))
                } catch {
                    return
                }

                await refresh()
            }
        }
    }

    private func trimHistory() {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        samples = Array(
            samples
                .filter { $0.timestamp >= sevenDaysAgo }
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(1_500)
        )
    }

    private var historyURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupport
            .appendingPathComponent("FastBar", isDirectory: true)
            .appendingPathComponent("speed-history.json")
    }

    private func loadHistory() {
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder.fastBar.decode([SpeedSample].self, from: data) else {
            return
        }

        samples = decoded.sorted { $0.timestamp < $1.timestamp }
        trimHistory()
    }

    private func saveHistory() {
        guard let historyURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.fastBar.encode(samples)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            lastError = "Could not save history: \(error.localizedDescription)"
        }
    }
}

@MainActor
private enum FastSpeedTest {
    private static let configurationURL = URL(
        string: "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=3"
    )!

    static func measure(bytesPerStream: Int) async throws -> SpeedSample {
        do {
            return try await measureWithFastDotCom()
        } catch is CancellationError {
            // A cancelled run must not silently fall through to the probes.
            throw CancellationError()
        } catch {
            do {
                return try await measureWithDirectProbe(bytesPerStream: bytesPerStream)
            } catch let fallbackError {
                throw SpeedTestError.allProbesFailed(
                    primary: error,
                    fallback: fallbackError
                )
            }
        }
    }

    private static func measureWithFastDotCom() async throws -> SpeedSample {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        var request = URLRequest(url: URL(string: "https://fast.com")!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        guard webView.load(request) != nil else {
            throw SpeedTestError.couldNotStart
        }

        // Covers the cancellation and timeout paths too, so an abandoned run
        // never keeps downloading in the background.
        defer { webView.stopLoading() }

        let clock = ContinuousClock()
        let start = clock.now
        let timeout: Duration = .seconds(60)

        while start.duration(to: clock.now) < timeout {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))

            do {
                let value = try await webView.evaluateJavaScript(
                    """
                    (() => {
                        const speedElement = document.querySelector('#speed-value');
                        const unitElement = document.querySelector('#speed-units');
                        const downloadedElement = document.querySelector('#down-mb-value');

                        return {
                            speed: Number(speedElement?.textContent) || 0,
                            unit: unitElement?.textContent?.trim() || 'Mbps',
                            downloadedMB: Number(downloadedElement?.textContent?.trim()) || 0,
                            succeeded: Boolean(speedElement?.classList.contains('succeeded'))
                        };
                    })()
                    """
                )

                guard let result = value as? [String: Any],
                      let speed = (result["speed"] as? NSNumber)?.doubleValue,
                      let unit = result["unit"] as? String,
                      (result["succeeded"] as? NSNumber)?.boolValue == true,
                      speed > 0 else {
                    continue
                }

                let elapsed = start.duration(to: clock.now).seconds
                let downloadedMB = (result["downloadedMB"] as? NSNumber)?.doubleValue ?? 0

                return SpeedSample(
                    downloadMbps: convertToMbps(speed, unit: unit),
                    source: .fastDotCom,
                    bytesDownloaded: Int(downloadedMB * 1_000_000),
                    duration: elapsed
                )
            } catch {
                // The page is not script-ready while it is navigating. Keep polling
                // until Fast.com completes the test or the overall timeout expires.
            }
        }

        throw SpeedTestError.timedOut
    }

    private static func convertToMbps(_ value: Double, unit: String) -> Double {
        switch unit {
        case "Gbps":
            return value * 1_000
        case "Kbps":
            return value / 1_000
        case "Bps":
            return value / 1_000_000
        default:
            return value
        }
    }

    private static func measureWithDirectProbe(bytesPerStream: Int) async throws -> SpeedSample {
        do {
            let targets = try await fetchFastTargets()
            let result = try await downloadInParallel(
                from: Array(targets.prefix(2)),
                bytesPerStream: bytesPerStream
            )

            return SpeedSample(
                downloadMbps: result.megabitsPerSecond,
                source: .fastProbeFallback,
                bytesDownloaded: result.bytes,
                duration: result.duration
            )
        } catch {
            let fallback = URL(
                string: "https://speed.cloudflare.com/__down?bytes=\(bytesPerStream)"
            )!
            let result = try await timedDownload(from: fallback, range: nil)

            return SpeedSample(
                downloadMbps: result.megabitsPerSecond,
                source: .cloudflareFallback,
                bytesDownloaded: result.bytes,
                duration: result.duration
            )
        }
    }

    private static func fetchFastTargets() async throws -> [URL] {
        var request = URLRequest(url: configurationURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)

        let configuration = try JSONDecoder().decode(FastConfiguration.self, from: data)
        let targets = configuration.targets.compactMap { URL(string: $0.url) }

        guard !targets.isEmpty else {
            throw SpeedTestError.noTargets
        }

        return targets
    }

    private static func downloadInParallel(
        from targets: [URL],
        bytesPerStream: Int
    ) async throws -> DownloadResult {
        guard !targets.isEmpty else {
            throw SpeedTestError.noTargets
        }

        let clock = ContinuousClock()
        let start = clock.now

        let totalBytes = try await withThrowingTaskGroup(of: Int.self) { group in
            for target in targets {
                group.addTask {
                    let result = try await timedDownload(
                        from: target,
                        range: 0..<(bytesPerStream)
                    )
                    return result.bytes
                }
            }

            var bytes = 0
            for try await count in group {
                bytes += count
            }
            return bytes
        }

        let elapsed = start.duration(to: clock.now).seconds
        guard elapsed > 0, totalBytes > 0 else {
            throw SpeedTestError.emptyDownload
        }

        return DownloadResult(bytes: totalBytes, duration: elapsed)
    }

    private static func timedDownload(from url: URL, range: Range<Int>?) async throws -> DownloadResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let range {
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = start.duration(to: clock.now).seconds
        try validate(response)

        guard !data.isEmpty, elapsed > 0 else {
            throw SpeedTestError.emptyDownload
        }

        return DownloadResult(bytes: data.count, duration: elapsed)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw SpeedTestError.badResponse
        }
    }
}

private struct FastConfiguration: Decodable {
    let targets: [FastTarget]
}

private struct FastTarget: Decodable {
    let url: String
}

private struct DownloadResult {
    let bytes: Int
    let duration: TimeInterval

    var megabitsPerSecond: Double {
        (Double(bytes) * 8) / duration / 1_000_000
    }
}

private enum SpeedTestError: LocalizedError {
    case noTargets
    case badResponse
    case emptyDownload
    case couldNotStart
    case timedOut
    case allProbesFailed(primary: any Error, fallback: any Error)

    var errorDescription: String? {
        switch self {
        case let .allProbesFailed(primary, fallback):
            return "Fast.com failed (\(primary.localizedDescription)) "
                + "and the fallback probe failed (\(fallback.localizedDescription))."
        case .noTargets:
            return "FAST returned no test servers."
        case .badResponse:
            return "The test server returned an error."
        case .emptyDownload:
            return "The test server returned no data."
        case .couldNotStart:
            return "The Fast.com test could not start."
        case .timedOut:
            return "The Fast.com test timed out."
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

private extension JSONEncoder {
    static var fastBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var fastBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
