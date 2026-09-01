import Combine
import CoreLocation
import SwiftUI

struct LocationDemoView: View {
    @StateObject private var controller = LocationDemoController()

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.spacingM) {
            HStack {
                Text("Core Location demo")
                    .font(.headline)
                Spacer()
                Button {
                    controller.requestLocation()
                } label: {
                    Label("Get location", systemImage: "location.fill")
                }
                .disabled(controller.isRequesting)
                .accessibilityIdentifier("location.demo.request")
            }

            Grid(alignment: .leading, horizontalSpacing: InterfaceMetrics.spacingL) {
                GridRow {
                    Text("Authorization").foregroundStyle(.secondary)
                    Text(controller.authorizationStatus)
                        .accessibilityIdentifier("location.demo.authorization")
                }
                GridRow {
                    Text("State").foregroundStyle(.secondary)
                    Text(controller.state)
                        .accessibilityIdentifier("location.demo.state")
                }
                if let coordinate = controller.coordinate {
                    GridRow {
                        Text("Latitude").foregroundStyle(.secondary)
                        Text(coordinate.latitude, format: .number.precision(.fractionLength(7)))
                            .accessibilityIdentifier("location.demo.latitude")
                    }
                    GridRow {
                        Text("Longitude").foregroundStyle(.secondary)
                        Text(coordinate.longitude, format: .number.precision(.fractionLength(7)))
                            .accessibilityIdentifier("location.demo.longitude")
                    }
                }
                if let accuracy = controller.horizontalAccuracy {
                    GridRow {
                        Text("Accuracy").foregroundStyle(.secondary)
                        Text("\(accuracy, format: .number.precision(.fractionLength(1))) m")
                    }
                }
            }
            .font(.caption)

            if let error = controller.error {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("location.demo.error")
            }

            ScrollView {
                Text(controller.events.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(InterfaceMetrics.spacingS)
            .background(.background.secondary, in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.fieldCornerRadius
            ))
        }
        .padding(InterfaceMetrics.spacingL)
        .frame(width: 520)
        .accessibilityIdentifier("location.demo.panel")
    }
}

@MainActor
private final class LocationDemoController: NSObject, ObservableObject,
    @preconcurrency CLLocationManagerDelegate
{
    @Published private(set) var authorizationStatus = "unknown"
    @Published private(set) var state = "Idle"
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var horizontalAccuracy: CLLocationAccuracy?
    @Published private(set) var error: String?
    @Published private(set) var events: [String] = []
    @Published private(set) var isRequesting = false

    private let manager = CLLocationManager()
    private var requestStarted = false

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = authorizationName(manager.authorizationStatus)
        record("initialized authorization=\(authorizationStatus)")
    }

    func requestLocation() {
        coordinate = nil
        horizontalAccuracy = nil
        error = nil
        isRequesting = true
        requestStarted = false
        let status = manager.authorizationStatus
        authorizationStatus = authorizationName(status)
        record("request tapped authorization=\(authorizationStatus)")
        if status == .notDetermined {
            state = "Requesting authorization"
            record("requestWhenInUseAuthorization()")
            manager.requestWhenInUseAuthorization()
        } else {
            continueWithAuthorization(status)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorizationStatus = authorizationName(status)
        record("authorization changed=\(authorizationStatus)")
        guard isRequesting else { return }
        continueWithAuthorization(status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        record("didUpdateLocations count=\(locations.count)")
        guard let location = locations.last else {
            record("empty locations array; keep waiting")
            return
        }
        guard location.horizontalAccuracy >= 0 else {
            record("invalid accuracy=\(location.horizontalAccuracy); keep waiting")
            return
        }
        manager.stopUpdatingLocation()
        coordinate = location.coordinate
        horizontalAccuracy = location.horizontalAccuracy
        state = "Location received"
        isRequesting = false
        record(
            "location latitude=\(location.coordinate.latitude) "
                + "longitude=\(location.coordinate.longitude) "
                + "accuracy=\(location.horizontalAccuracy)"
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        // kCLErrorLocationUnknown (code 0) is transient: CoreLocation keeps trying,
        // so keep the continuous update running instead of giving up.
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.locationUnknown.rawValue {
            record("transient locationUnknown (code 0); keep updating")
            return
        }
        finishWithError(
            "domain=\(nsError.domain) code=\(nsError.code) "
                + "description=\(nsError.localizedDescription)"
        )
    }

    private func continueWithAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorized, .authorizedAlways:
            guard !requestStarted else {
                record("duplicate request ignored")
                return
            }
            requestStarted = true
            state = "Requesting location"
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            record("startUpdatingLocation()")
            manager.startUpdatingLocation()
        case .denied, .restricted:
            finishWithError("authorization=\(authorizationName(status))")
        case .notDetermined:
            state = "Waiting for authorization"
        @unknown default:
            finishWithError("authorization=unknown")
        }
    }

    private func finishWithError(_ message: String) {
        error = message
        state = "Failed"
        isRequesting = false
        record("failed \(message)")
    }

    private func record(_ message: String) {
        events.append("\(Date().ISO8601Format()) \(message)")
    }

    private func authorizationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "authorized_always"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }
}