import AppIntents
import Foundation

// MARK: - Metric Entity

/// A system metric Blip monitors, exposed to Shortcuts as a dynamic entity so
/// "Get System Metric" offers the full searchable catalog.
struct MetricEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Blip Metric")
    static let defaultQuery = MetricEntityQuery()

    /// MetricID raw value (stable — saved Shortcuts reference it).
    var id: String

    @Property(title: "Name")
    var title: String

    @Property(title: "Supports History")
    var supportsHistory: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            image: .init(systemName: MetricCatalog.descriptor(forRawID: id)?.symbol ?? "gauge")
        )
    }

    init(descriptor: MetricDescriptor) {
        self.id = descriptor.id.rawValue
        self.title = descriptor.title
        self.supportsHistory = descriptor.hasHistory
    }
}

struct MetricEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MetricEntity] {
        identifiers.compactMap { MetricCatalog.descriptor(forRawID: $0).map(MetricEntity.init) }
    }

    func suggestedEntities() async throws -> [MetricEntity] {
        MetricCatalog.all.map(MetricEntity.init)
    }

    func entities(matching string: String) async throws -> [MetricEntity] {
        MetricCatalog.all
            .filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.rawValue.localizedCaseInsensitiveContains(string) }
            .map(MetricEntity.init)
    }
}

// MARK: - Statistic

enum MetricStatistic: String, AppEnum {
    case current
    case average
    case minimum
    case maximum

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Statistic"
    static let caseDisplayRepresentations: [MetricStatistic: DisplayRepresentation] = [
        .current: "Current",
        .average: "Average (last 2 min)",
        .minimum: "Minimum (last 2 min)",
        .maximum: "Maximum (last 2 min)",
    ]

    var kind: MetricStatisticKind {
        MetricStatisticKind(rawValue: rawValue) ?? .current
    }
}

// MARK: - Errors

enum BlipIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case unknownMetric
    case metricUnavailable(String)
    case historyUnavailable(String)
    case invalidHost(String)
    case volumeNotMounted(String)
    case busy(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Blip is still starting up — try again in a moment."
        case .unknownMetric:
            return "That metric doesn't exist."
        case .metricUnavailable(let name):
            return "\(name) isn't available on this Mac right now."
        case .historyUnavailable(let name):
            return "\(name) is current-value only — Blip doesn't keep history for it."
        case .invalidHost(let host):
            return "“\(host)” isn't a valid hostname or IP address."
        case .volumeNotMounted(let name):
            return "The volume “\(name)” isn't mounted."
        case .busy(let message):
            return "\(message)"
        case .failed(let message):
            return "\(message)"
        }
    }
}

// MARK: - Get Metric

struct GetMetricIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Metric"
    static let description = IntentDescription(
        "Reads one of Blip's live system metrics — CPU, memory, disk and S.M.A.R.T., GPU, network, battery, temperatures, fans, uptime. Returns a number you can chain into other actions. For charted metrics you can also ask for the average, minimum, or maximum over Blip's in-memory history (the last ~2 minutes while the app is running).",
        categoryName: "Metrics"
    )

    @Parameter(title: "Metric")
    var metric: MetricEntity

    @Parameter(title: "Statistic", default: .current)
    var statistic: MetricStatistic

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$statistic) \(\.$metric)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let source = AppIntentsEnvironment.metricSource else { throw BlipIntentError.appNotReady }
        guard let descriptor = MetricCatalog.descriptor(forRawID: metric.id) else { throw BlipIntentError.unknownMetric }

        await source.ensureFreshSample()

        let value: Double?
        if statistic == .current {
            value = MetricMapper.value(of: descriptor.id, in: source.metricSnapshot)
        } else {
            guard descriptor.hasHistory else { throw BlipIntentError.historyUnavailable(descriptor.title) }
            guard let history = source.metricHistory(descriptor.id), !history.isEmpty else {
                throw BlipIntentError.metricUnavailable(descriptor.title)
            }
            value = MetricMapper.reduce(history, statistic: statistic.kind)
        }

        guard let value else { throw BlipIntentError.metricUnavailable(descriptor.title) }

        let formatted = MetricFormatter.format(value, unit: descriptor.unit)
        let prefix: String
        switch statistic {
        case .current: prefix = ""
        case .average: prefix = "average "
        case .minimum: prefix = "minimum "
        case .maximum: prefix = "maximum "
        }
        return .result(value: value, dialog: "\(descriptor.title) (\(prefix.isEmpty ? "now" : prefix.trimmingCharacters(in: .whitespaces) + ", last 2 min")): \(formatted)")
    }
}
