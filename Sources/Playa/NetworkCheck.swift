import Foundation
import PlayaCore

/// Measures how fast this device's internet connection is right now. It downloads from Apple's
/// network quality server (the one macOS's `networkQuality` tool uses), never from the TV
/// provider, so it can't count as a second stream on the subscription.
enum NetworkCheck {
    private static let url = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/large")!

    /// Downloads for up to `duration` seconds, or `maxBytes`, whichever comes first.
    static func measure(duration: TimeInterval = 3, maxBytes: Int = 50_000_000) async -> BufferingReason.Check {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6
        let meter = Meter(duration: duration, maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { continuation in
            meter.continuation = continuation
            session.dataTask(with: url).resume()
        }
    }

    private final class Meter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let duration: TimeInterval
        let maxBytes: Int
        var continuation: CheckedContinuation<BufferingReason.Check, Never>?
        // Delegate calls arrive one at a time on the session's serial queue.
        private var bytes = 0
        private var firstByte: Date?
        private var lastByte: Date?

        init(duration: TimeInterval, maxBytes: Int) {
            self.duration = duration
            self.maxBytes = maxBytes
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let now = Date()
            // Timed from the first data, so the connection's setup doesn't count against it.
            if let firstByte {
                bytes += data.count
                lastByte = now
                if bytes >= maxBytes || now.timeIntervalSince(firstByte) >= duration { dataTask.cancel() }
            } else {
                firstByte = now
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: BufferingReason.Check
            if let firstByte, let lastByte, lastByte.timeIntervalSince(firstByte) > 0.2 {
                result = .speed(bytesPerSecond: Double(bytes) / lastByte.timeIntervalSince(firstByte))
            } else if firstByte != nil {
                // Too little arrived to time; the connection is working at least.
                result = .failed
            } else if let error = error as? URLError, Self.offlineCodes.contains(error.code) {
                result = .offline
            } else {
                result = .failed
            }
            continuation?.resume(returning: result)
            continuation = nil
        }

        private static let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
        ]
    }
}
