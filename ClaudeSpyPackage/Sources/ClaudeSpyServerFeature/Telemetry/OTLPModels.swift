import Foundation

// MARK: - OTLP/JSON wire models (issue #597)
//
// Minimal `Decodable` shapes for the slices of OTLP/JSON we consume from Claude
// Code's OpenTelemetry export — metrics (`POST /v1/metrics`) and logs
// (`POST /v1/logs`). We deliberately decode only the fields we need and ignore
// the rest, so schema growth on the producer side never breaks ingestion.
//
// A note on numbers: the proto3 → JSON mapping serializes int64/uint64/fixed64
// as JSON **strings** (e.g. `"asInt": "1234"`), but some exporters emit them as
// JSON numbers. `OTLPScalar` accepts either, so both forms decode.

// MARK: Metrics

struct OTLPMetricsRequest: Decodable {
    let resourceMetrics: [OTLPResourceMetrics]?
}

struct OTLPResourceMetrics: Decodable {
    let scopeMetrics: [OTLPScopeMetrics]?
}

struct OTLPScopeMetrics: Decodable {
    let metrics: [OTLPMetric]?
}

struct OTLPMetric: Decodable {
    let name: String?
    let sum: OTLPSum?
    let gauge: OTLPGauge?
}

struct OTLPSum: Decodable {
    let dataPoints: [OTLPNumberDataPoint]?
}

struct OTLPGauge: Decodable {
    let dataPoints: [OTLPNumberDataPoint]?
}

struct OTLPNumberDataPoint: Decodable {
    let attributes: [OTLPKeyValue]?
    let asInt: OTLPScalar?
    let asDouble: OTLPScalar?

    /// The numeric value of this data point regardless of int/double encoding.
    var value: Double {
        asDouble?.doubleValue ?? asInt?.doubleValue ?? 0
    }
}

// MARK: Logs

struct OTLPLogsRequest: Decodable {
    let resourceLogs: [OTLPResourceLogs]?
}

struct OTLPResourceLogs: Decodable {
    let scopeLogs: [OTLPScopeLogs]?
}

struct OTLPScopeLogs: Decodable {
    let logRecords: [OTLPLogRecord]?
}

struct OTLPLogRecord: Decodable {
    /// The OTLP `eventName` field (newer SDKs). Falls back to the `event.name`
    /// attribute or the string body via ``eventName(attributesByKey:)``.
    let eventName: String?
    let body: OTLPAnyValue?
    let attributes: [OTLPKeyValue]?
}

// MARK: Attributes

struct OTLPKeyValue: Decodable {
    let key: String
    let value: OTLPAnyValue?
}

/// An OTLP `AnyValue`. Only the variants we read are modeled; everything else
/// (arrays, kvlists, bytes) decodes to `nil` and is ignored.
struct OTLPAnyValue: Decodable {
    let stringValue: String?
    let intValue: Int?
    let doubleValue: Double?
    let boolValue: Bool?

    private enum CodingKeys: String, CodingKey {
        case stringValue
        case intValue
        case doubleValue
        case boolValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stringValue = try container.decodeIfPresent(String.self, forKey: .stringValue)
        self.boolValue = try container.decodeIfPresent(Bool.self, forKey: .boolValue)
        self.intValue = (try? container.decodeIfPresent(OTLPScalar.self, forKey: .intValue))??.intValue
        self.doubleValue = (try? container.decodeIfPresent(OTLPScalar.self, forKey: .doubleValue))??.doubleValue
    }

    /// Convenience: the numeric value (int or double), if either is present.
    var numeric: Double? {
        doubleValue ?? intValue.map(Double.init)
    }
}

/// A JSON scalar that may arrive as a number or a numeric string (the proto3
/// JSON int64 encoding). Decodes from either form.
struct OTLPScalar: Decodable {
    let doubleValue: Double

    var intValue: Int {
        Int(doubleValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let asDouble = try? container.decode(Double.self) {
            self.doubleValue = asDouble
        } else if let asString = try? container.decode(String.self), let parsed = Double(asString) {
            self.doubleValue = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "OTLP scalar is neither a number nor a numeric string"
            )
        }
    }
}

// MARK: - Attribute lookup helpers

extension Array where Element == OTLPKeyValue {
    /// Returns the `AnyValue` for `key`, if present.
    func value(for key: String) -> OTLPAnyValue? {
        first(where: { $0.key == key })?.value
    }

    func string(for key: String) -> String? {
        value(for: key)?.stringValue
    }

    func int(for key: String) -> Int? {
        guard let value = value(for: key) else { return nil }
        return value.intValue ?? value.doubleValue.map(Int.init)
    }

    func double(for key: String) -> Double? {
        value(for: key)?.numeric
    }
}

extension OTLPLogRecord {
    /// Resolves the event name from, in order: the `eventName` field, the
    /// `event.name` attribute, then a string body. Claude Code's exporter has
    /// used the attribute form; the field form is the newer OTLP convention.
    func resolvedEventName() -> String? {
        if let eventName, !eventName.isEmpty { return eventName }
        if let attributeName = attributes?.string(for: "event.name"), !attributeName.isEmpty {
            return attributeName
        }
        if let bodyString = body?.stringValue, !bodyString.isEmpty { return bodyString }
        return nil
    }
}
