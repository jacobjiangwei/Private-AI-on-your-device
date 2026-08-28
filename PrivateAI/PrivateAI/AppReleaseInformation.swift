import Foundation

enum AppReleaseInformation {
    static var privacyPolicyURL: URL? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "PrivateAIPrivacyPolicyURL"
        ) as? String,
        !value.isEmpty,
        let url = URL(string: value),
        url.scheme == "https"
        else { return nil }
        return url
    }
}