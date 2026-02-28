import Foundation

struct WowInternalMetricsPayload: Codable {
    let version: Int
    let metrics: [String: Double]
    let failureReasons: [String: String]

    enum CodingKeys: String, CodingKey {
        case version
        case metrics
        case failureReasons = "failure_reasons"
    }
}

func loadWowInternalMetrics(from path: String) -> WowInternalMetricsPayload? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(WowInternalMetricsPayload.self, from: data)
    } catch {
        return nil
    }
}

