@preconcurrency import CoreLocation
import Darwin
import Foundation
import IOKit.ps
@preconcurrency import MapKit

public enum LocalContextError: LocalizedError, Sendable {
    case invalidFields
    case locationServicesDisabled
    case locationPermissionDenied
    case locationPermissionRestricted
    case locationBusy
    case locationTimedOut
    case locationUnavailable(String)
    case publicIPUnavailable(String)
    case localSearchUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFields:
            String(localized: "The local context action requires one or more supported fields.")
        case .locationServicesDisabled:
            String(localized: "Location services are disabled on this Mac.")
        case .locationPermissionDenied:
            String(localized: "Location permission was denied. Enable it in macOS Privacy & Security settings.")
        case .locationPermissionRestricted:
            String(localized: "Location access is restricted by macOS policy or parental controls.")
        case .locationBusy:
            String(localized: "A location request is already in progress.")
        case .locationTimedOut:
            String(localized: "The location request timed out.")
        case .locationUnavailable(let detail):
            String(localized: "Location is unavailable: \(detail)")
        case .publicIPUnavailable(let detail):
            String(localized: "Public IP lookup failed: \(detail)")
        case .localSearchUnavailable(let detail):
            String(localized: "Apple Maps local search failed: \(detail)")
        }
    }
}

public protocol LocalSearching: Sendable {
    func search(
        query: String,
        radiusKilometers: Double,
        maximumResults: Int,
        usesChineseLabels: Bool
    ) async throws -> ToolResult
}

public actor LocalSearchProvider: LocalSearching {
            public init() {}

            public func search(
                query: String,
                radiusKilometers: Double,
                maximumResults: Int,
                usesChineseLabels: Bool = false
            ) async throws -> ToolResult {
                let location = try await LocationResolver.shared.resolve()
                return try await search(
                    query: query,
                    radiusKilometers: radiusKilometers,
                    maximumResults: maximumResults,
                    near: location,
                    usesChineseLabels: usesChineseLabels
                )
            }

            public func search(
                query: String,
                radiusKilometers: Double,
                maximumResults: Int,
                near location: CLLocation,
                usesChineseLabels: Bool = false
            ) async throws -> ToolResult {
                let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw LocalContextError.localSearchUnavailable("the search query is empty")
                }
                let radius = min(max(radiusKilometers, 0.5), 50)
                let maximum = min(max(maximumResults, 1), 12)
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = normalized
                request.resultTypes = .pointOfInterest
                request.region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: radius * 2_000,
                    longitudinalMeters: radius * 2_000
                )
                let search = MKLocalSearch(request: request)
                do {
                    let response = try await withTaskCancellationHandler {
                        try await search.start()
                    } onCancel: {
                        search.cancel()
                    }
                    try Task.checkCancellation()
                    let nearby = response.mapItems.compactMap { item -> NearbyPlace? in
                        guard let name = item.name, !name.isEmpty else { return nil }
                        let distance = item.placemark.location?.distance(from: location)
                            ?? .greatestFiniteMagnitude
                        guard distance <= radius * 1_500 else { return nil }
                        let coordinate = item.placemark.coordinate
                        var components = URLComponents(string: "https://maps.apple.com/")
                        components?.queryItems = [
                            URLQueryItem(name: "q", value: name),
                            URLQueryItem(
                                name: "ll",
                                value: "\(coordinate.latitude),\(coordinate.longitude)"
                            )
                        ]
                        guard let mapsURL = components?.url?.absoluteString else { return nil }
                        return NearbyPlace(
                            name: name,
                            category: item.pointOfInterestCategory?.rawValue,
                            distanceMeters: distance,
                            address: item.placemark.title,
                            phone: item.phoneNumber,
                            website: item.url?.absoluteString,
                            mapsURL: mapsURL
                        )
                    }
                    .sorted { $0.distanceMeters < $1.distanceMeters }
                    .prefix(maximum)

                    guard !nearby.isEmpty else {
                        throw LocalContextError.localSearchUnavailable(
                            "Apple Maps returned no places within \(Self.distance(radius * 1_000))"
                        )
                    }
                    let places = Array(nearby)
                    let content = places.enumerated().map { index, place in
                        [
                            "\(index + 1). \(place.name)",
                            place.category.map { "Category: \($0)" },
                            "Distance: \(Self.distance(place.distanceMeters))",
                            place.address.map { "Address: \($0)" },
                            place.phone.map { "Phone: \($0)" },
                            place.website.map { "Website: \($0)" },
                            "Apple Maps: \(place.mapsURL)"
                        ].compactMap { $0 }.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                    return ToolResult(
                        content: content,
                        summary: "Found \(places.count) nearby place\(places.count == 1 ? "" : "s") with Apple Maps",
                        sources: places.map {
                            SourceLink(title: $0.name, url: $0.mapsURL)
                        },
                        groundedAnswer: Self.groundedAnswer(
                            for: places,
                            usesChineseLabels: usesChineseLabels
                        )
                    )
                } catch let error as LocalContextError {
                    throw error
                } catch {
                    throw LocalContextError.localSearchUnavailable(error.localizedDescription)
                }
            }

            private static func distance(_ meters: Double) -> String {
                if meters < 1_000 {
                    return "\(Int(meters.rounded())) m"
                }
                return String(format: "%.1f km", meters / 1_000)
            }

            private static func groundedAnswer(
                for places: [NearbyPlace],
                usesChineseLabels: Bool
            ) -> String {
                let heading = usesChineseLabels
                    ? "Apple Maps 找到以下附近地点，已按距离排序："
                    : "Apple Maps found these nearby places, sorted by distance:"
                let rows = places.enumerated().map { index, place in
                    var lines = [
                        "\(index + 1). **\(place.name)**",
                        usesChineseLabels
                            ? "   - 距离：\(distance(place.distanceMeters))"
                            : "   - Distance: \(distance(place.distanceMeters))"
                    ]
                    if let address = place.address, !address.isEmpty {
                        lines.append(
                            usesChineseLabels
                                ? "   - 地址：\(address)"
                                : "   - Address: \(address)"
                        )
                    }
                    if let phone = place.phone, !phone.isEmpty {
                        lines.append(
                            usesChineseLabels
                                ? "   - 电话：\(phone)"
                                : "   - Phone: \(phone)"
                        )
                    }
                    return lines.joined(separator: "\n")
                }.joined(separator: "\n\n")
                let caveat = usesChineseLabels
                    ? "Apple Maps 没有返回评分或实时营业状态，请打开地点链接确认。"
                    : "Apple Maps did not return ratings or live opening status; open a place link to confirm."
                return "\(heading)\n\n\(rows)\n\n\(caveat)"
            }

            private struct NearbyPlace {
                let name: String
                let category: String?
                let distanceMeters: Double
                let address: String?
                let phone: String?
                let website: String?
                let mapsURL: String
            }
}

public enum LocalContextField: String, CaseIterable, Sendable {
    case time
    case locale
    case device
    case power
    case storage
    case localNetwork = "local_network"
    case publicIP = "public_ip"
    case location
}

public actor LocalContextProvider {
    private let resolveLocation: @Sendable () async throws -> CLLocation
    private let describeLocation: @Sendable (CLLocation) async -> [String: JSONValue]

    public init() {
        self.resolveLocation = {
            try await LocationResolver.shared.resolve()
        }
        self.describeLocation = {
            await LocationNameResolver.shared.describe($0)
        }
    }

    init(
        resolveLocation: @escaping @Sendable () async throws -> CLLocation,
        describeLocation: @escaping @Sendable (CLLocation) async -> [String: JSONValue]
    ) {
        self.resolveLocation = resolveLocation
        self.describeLocation = describeLocation
    }

    public func collect(fields: [LocalContextField]) async throws -> ToolResult {
        guard !fields.isEmpty else { throw LocalContextError.invalidFields }
        var values: [String: JSONValue] = [:]
        for field in fields {
            try Task.checkCancellation()
            switch field {
            case .time:
                values[field.rawValue] = .object(Self.timeContext())
            case .locale:
                values[field.rawValue] = .object(Self.localeContext())
            case .device:
                values[field.rawValue] = .object(Self.deviceContext())
            case .power:
                values[field.rawValue] = .object(Self.powerContext())
            case .storage:
                values[field.rawValue] = .object(Self.storageContext())
            case .localNetwork:
                values[field.rawValue] = .array(Self.localNetworkContext())
            case .publicIP:
                values[field.rawValue] = .object(try await Self.publicIPContext())
            case .location:
                let location = try await resolveLocation()
                var context: [String: JSONValue] = [
                    "latitude": .number(location.coordinate.latitude),
                    "longitude": .number(location.coordinate.longitude),
                    "horizontal_accuracy_meters": .number(location.horizontalAccuracy),
                    "timestamp": .string(
                        ISO8601DateFormatter().string(from: location.timestamp)
                    ),
                    "source": .string("macOS Core Location")
                ]
                context.merge(await describeLocation(location)) { _, latest in
                    latest
                }
                values[field.rawValue] = .object(context)
            }
        }
        try Task.checkCancellation()
        let data = try JSONEncoder.prettySorted.encode(JSONValue.object(values))
        return ToolResult(
            content: String(decoding: data, as: UTF8.self),
            summary: "Read \(fields.count) local context field\(fields.count == 1 ? "" : "s")"
        )
    }

    private static func timeContext() -> [String: JSONValue] {
        let now = Date()
        let zone = TimeZone.current
        return [
            "iso8601": .string(ISO8601DateFormatter().string(from: now)),
            "time_zone": .string(zone.identifier),
            "time_zone_abbreviation": .string(zone.abbreviation(for: now) ?? ""),
            "utc_offset_seconds": .number(Double(zone.secondsFromGMT(for: now)))
        ]
    }

    private static func localeContext() -> [String: JSONValue] {
        let locale = Locale.current
        return [
            "identifier": .string(locale.identifier),
            "preferred_languages": .array(
                Locale.preferredLanguages.prefix(6).map(JSONValue.string)
            ),
            "measurement_system": .string(locale.measurementSystem.identifier)
        ]
    }

    private static func deviceContext() -> [String: JSONValue] {
        let process = ProcessInfo.processInfo
        return [
            "model_identifier": .string(sysctlString("hw.model") ?? "unknown"),
            "architecture": .string(sysctlString("hw.machine") ?? "unknown"),
            "operating_system": .string(process.operatingSystemVersionString),
            "processor_count": .number(Double(process.processorCount)),
            "active_processor_count": .number(Double(process.activeProcessorCount)),
            "physical_memory_bytes": .number(Double(process.physicalMemory)),
            "low_power_mode": .bool(process.isLowPowerModeEnabled)
        ]
    }

    private static func powerContext() -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)
        ]
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            result["battery_present"] = .bool(false)
            return result
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            result["battery_present"] = .bool(true)
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                result["battery_percent"] = .number(
                    Double(current) / Double(maximum) * 100
                )
            }
            if let charging = description[kIOPSIsChargingKey] as? Bool {
                result["is_charging"] = .bool(charging)
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                result["power_source"] = .string(state)
            }
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes >= 0 {
                result["time_to_empty_minutes"] = .number(Double(minutes))
            }
            break
        }
        if result["battery_present"] == nil {
            result["battery_present"] = .bool(false)
        }
        return result
    }

    private static func storageContext() -> [String: JSONValue] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        var result: [String: JSONValue] = [:]
        if let total = values?.volumeTotalCapacity {
            result["total_bytes"] = .number(Double(total))
        }
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            result["available_bytes"] = .number(Double(available))
        }
        return result
    }

    private static func localNetworkContext() -> [JSONValue] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }
        var output: [JSONValue] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let value = decodeCString(host)
            guard !value.hasPrefix("fe80:") else { continue }
            output.append(.object([
                "interface": .string(String(cString: interface.pointee.ifa_name)),
                "family": .string(family == AF_INET ? "IPv4" : "IPv6"),
                "address": .string(value)
            ]))
        }
        return output
    }

    private static func publicIPContext() async throws -> [String: JSONValue] {
        do {
            let text = try await boundedText(
                from: URL(string: "https://1.1.1.1/cdn-cgi/trace")!
            )
            let values = Dictionary(
                uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? (parts[0], parts[1]) : nil
                }
            )
            if let ip = values["ip"], isIPAddress(ip) {
                var result: [String: JSONValue] = [
                    "address": .string(ip),
                    "provider": .string("Cloudflare trace")
                ]
                if let country = values["loc"], country.count == 2 {
                    result["country_code"] = .string(country)
                }
                return result
            }
        } catch {
            // Fall through to the independent IP-only provider.
        }
        do {
            let text = try await boundedText(
                from: URL(string: "https://api.ipify.org?format=json")!
            )
            guard let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let ip = object["ip"] as? String,
                  isIPAddress(ip)
            else {
                throw LocalContextError.publicIPUnavailable("ipify returned invalid data")
            }
            return [
                "address": .string(ip),
                "provider": .string("ipify")
            ]
        } catch let error as LocalContextError {
            throw error
        } catch {
            throw LocalContextError.publicIPUnavailable(error.localizedDescription)
        }
    }

    private static func boundedText(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("LocalChat/0.1", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LocalContextError.publicIPUnavailable("provider returned a non-success response")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_096 else {
                throw LocalContextError.publicIPUnavailable("provider response was too large")
            }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return decodeCString(bytes)
    }

    private static func decodeCString(_ bytes: [CChar]) -> String {
        let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: content, as: UTF8.self)
    }
}

private actor LocationNameResolver {
    static let shared = LocationNameResolver()

    private let geocoder = CLGeocoder()

    func describe(_ location: CLLocation) async -> [String: JSONValue] {
        do {
            guard let placemark = try await geocoder.reverseGeocodeLocation(
                location
            ).first else {
                return ["place_name_status": .string("unavailable")]
            }
            var result: [String: JSONValue] = [
                "place_name_status": .string("available"),
                "place_name_source": .string("Apple reverse geocoding")
            ]
            if let city = placemark.locality ?? placemark.subAdministrativeArea {
                result["city"] = .string(city)
            }
            if let district = placemark.subLocality {
                result["district"] = .string(district)
            }
            if let region = placemark.administrativeArea {
                result["administrative_area"] = .string(region)
            }
            if let country = placemark.country {
                result["country"] = .string(country)
            }
            if let countryCode = placemark.isoCountryCode {
                result["country_code"] = .string(countryCode)
            }
            if Set(result.keys).isDisjoint(with: [
                "city", "district", "administrative_area", "country"
            ]) {
                result["place_name_status"] = .string("unavailable")
            }
            return result
        } catch is CancellationError {
            return ["place_name_status": .string("cancelled")]
        } catch {
            return ["place_name_status": .string("unavailable")]
        }
    }
}

@MainActor
protocol LocationManagerControlling: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestLocation()
    func requestWhenInUseAuthorization()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationManagerControlling {}

private final class LocationCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledRequestIDs: Set<UUID> = []

    func markCancelled(_ requestID: UUID) {
        lock.withLock { _ = cancelledRequestIDs.insert(requestID) }
    }

    func consumeCancellation(_ requestID: UUID) -> Bool {
        lock.withLock { cancelledRequestIDs.remove(requestID) != nil }
    }

    func clear(_ requestID: UUID) {
        lock.withLock { _ = cancelledRequestIDs.remove(requestID) }
    }
}

@MainActor
final class LocationResolver: NSObject, @MainActor CLLocationManagerDelegate {
    static let shared = LocationResolver()

    private enum Phase {
        case idle
        case awaitingAuthorization
        case requestingLocation
    }

    private let manager: any LocationManagerControlling
    private let locationServicesEnabled: () -> Bool
    private let timeout: Duration
    private let now: () -> Date
    private let maximumHorizontalAccuracy: CLLocationAccuracy
    private let cachedLocationTolerance: TimeInterval
    private let cancellationRegistry = LocationCancellationRegistry()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var requestID: UUID?
    private var requestStartedAt: Date?
    private var phase: Phase = .idle

    init(
        manager: any LocationManagerControlling = CLLocationManager(),
        locationServicesEnabled: @escaping () -> Bool = {
            CLLocationManager.locationServicesEnabled()
        },
        timeout: Duration = .seconds(15),
        now: @escaping () -> Date = Date.init,
        maximumHorizontalAccuracy: CLLocationAccuracy = 5_000,
        cachedLocationTolerance: TimeInterval = 15
    ) {
        self.manager = manager
        self.locationServicesEnabled = locationServicesEnabled
        self.timeout = timeout
        self.now = now
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.cachedLocationTolerance = cachedLocationTolerance
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func resolve() async throws -> CLLocation {
        try Task.checkCancellation()
        guard locationServicesEnabled() else {
            throw LocalContextError.locationServicesDisabled
        }
        guard continuation == nil else { throw LocalContextError.locationBusy }
        let identifier = UUID()
        cancellationRegistry.clear(identifier)
        requestID = identifier
        requestStartedAt = now()
        phase = .idle
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                beginRequestForCurrentAuthorization()
                Task { @MainActor [weak self, timeout] in
                    try? await Task.sleep(for: timeout)
                    guard self?.requestID == identifier else { return }
                    self?.finish(.failure(LocalContextError.locationTimedOut))
                }
            }
        } onCancel: { [cancellationRegistry] in
            cancellationRegistry.markCancelled(identifier)
            Task { @MainActor [weak self] in
                self?.cancelRequest(identifier)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        beginRequestForCurrentAuthorization()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard continuation != nil, phase == .requestingLocation else { return }
        guard let requestStartedAt else { return }
        let latestAcceptedTimestamp = now().addingTimeInterval(5)
        guard let location = locations.reversed().first(where: {
            $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= maximumHorizontalAccuracy
                && $0.timestamp >= requestStartedAt.addingTimeInterval(
                    -cachedLocationTolerance
                )
                && $0.timestamp <= latestAcceptedTimestamp
        }) else {
            finish(.failure(LocalContextError.locationUnavailable(
                "no fresh, accurate location was returned"
            )))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard continuation != nil, phase == .requestingLocation else { return }
        if let locationError = error as? CLError,
           locationError.code == .denied {
            finish(.failure(LocalContextError.locationPermissionDenied))
        } else {
            finish(.failure(LocalContextError.locationUnavailable(
                error.localizedDescription
            )))
        }
    }

    private func beginRequestForCurrentAuthorization() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            guard phase != .requestingLocation else { return }
            phase = .requestingLocation
            manager.requestLocation()
        case .notDetermined:
            guard phase != .awaitingAuthorization else { return }
            phase = .awaitingAuthorization
            manager.requestWhenInUseAuthorization()
        case .denied:
            finish(.failure(LocalContextError.locationPermissionDenied))
        case .restricted:
            finish(.failure(LocalContextError.locationPermissionRestricted))
        @unknown default:
            finish(.failure(LocalContextError.locationUnavailable("unknown authorization state")))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        let identifier = requestID
        manager.stopUpdatingLocation()
        self.continuation = nil
        requestID = nil
        requestStartedAt = nil
        phase = .idle
        if let identifier,
           cancellationRegistry.consumeCancellation(identifier) {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(with: result)
        }
    }

    private func cancelRequest(_ identifier: UUID) {
        guard requestID == identifier else { return }
        finish(.failure(CancellationError()))
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
