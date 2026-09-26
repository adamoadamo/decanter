import Foundation

/// New versions are published as GitHub releases, tagged like "v1.2", with the notarised
/// zip attached. Decanter compares the latest one with its own version.
enum Updates {
    static let repo = "adamoadamo/decanter"

    struct Release: Decodable, Identifiable {
        let tagName: String
        let htmlURL: URL
        let body: String?

        var id: String { tagName }
        var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", body
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The newest published release, or nil if there isn't one yet (GitHub answers 404).
    static func latest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(Release.self, from: data)
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }

    /// Compares dotted versions number by number, so 1.10 is newer than 1.9 and 1.2 equals 1.2.0.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}
