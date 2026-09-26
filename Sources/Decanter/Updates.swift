import Foundation
import Security

/// New versions are published as GitHub releases, tagged like "v1.2", with the notarised
/// zip attached. Decanter compares the latest one with its own version, and can download
/// it and install it in place of itself.
enum Updates {
    static let repo = "adamoadamo/decanter"

    enum Status: Equatable {
        case unknown, checking, upToDate, failed
        case available(Release)
        case installing(Release)

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    struct Release: Decodable, Identifiable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name, url = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]

        var id: String { tagName }
        var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
        /// Where to download the notarised app, as a zip.
        var zip: URL? { assets.first { $0.name.hasSuffix(".zip") }?.url }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", body, assets
        }
    }

    enum InstallError: LocalizedError {
        case noDownload, downloadFailed, notReplaceable, notDecanter, notNewer, notSigned

        var errorDescription: String? {
            switch self {
            case .noDownload: "The new version has nothing to download yet."
            case .downloadFailed: "The download didn’t work. Check your internet connection."
            case .notReplaceable: "Decanter can’t put the new version where it is or in Applications."
            case .notDecanter: "The download isn’t a copy of Decanter."
            case .notNewer: "The download isn’t newer than this copy of Decanter."
            case .notSigned: "The download isn’t signed by Decanter’s developer."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Where to find out about the latest release. To try an update without publishing it, point
    /// the UpdateFeed setting somewhere else, for example with `-UpdateFeed file:///…/latest.json`
    /// on the command line. Whatever it points to still has to pass the signature check.
    private static var feed: URL {
        UserDefaults.standard.string(forKey: "UpdateFeed").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// The newest published release, or nil if there isn't one yet (GitHub answers 404).
    static func latest() async throws -> Release? {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200, nil: return try JSONDecoder().decode(Release.self, from: data)
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

    // MARK: Installing

    /// Downloads a release and puts it where this copy of Decanter is, or in Applications if
    /// this copy can't be replaced. It returns where the new copy went. The running app is
    /// still the old one until that's opened.
    static func install(_ release: Release) async throws -> URL {
        guard let zip = release.zip else { throw InstallError.noDownload }
        let fm = FileManager.default
        let here = Bundle.main.bundleURL
        // macOS runs an app opened straight from Downloads or a disk image from a hidden,
        // read-only copy. That can't be replaced, so the update goes into Applications.
        let replaceable = !here.path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: here.deletingLastPathComponent().path)
        let destination = replaceable ? here : URL(fileURLWithPath: "/Applications/Decanter.app")
        if !replaceable {
            let existing = Bundle(url: destination)?.bundleIdentifier
            guard fm.isWritableFile(atPath: "/Applications"), existing == nil || existing == Bundle.main.bundleIdentifier else {
                throw InstallError.notReplaceable
            }
        }
        // Work on the same disk as the destination, so putting the new copy in place is just a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: work) }
        let (download, response) = try await URLSession.shared.download(from: zip)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw InstallError.downloadFailed
        }
        let archive = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: download, to: archive)
        guard try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, work.path]) == 0,
              let new = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw InstallError.notDecanter
        }
        // Never install an older version, or the same one again, which would be offered on every launch.
        guard let version = Bundle(url: new)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              isNewer(version, than: currentVersion) else {
            throw InstallError.notNewer
        }
        try checkSignature(of: new)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: new)
        } else {
            try fm.moveItem(at: new, to: destination)
        }
        return destination
    }

    /// The new copy has to meet this copy's own code signing requirement: for a release, the
    /// same Developer ID and bundle id. A development build's requirement is its own exact
    /// code, so it never replaces itself with a download.
    private static func checkSignature(of new: URL) throws {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(new as CFURL, [], &theirs) == errSecSuccess, let theirs,
              SecStaticCodeCheckValidity(theirs, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
                                                                     | kSecCSStrictValidate),
                                         requirement) == errSecSuccess else {
            throw InstallError.notSigned
        }
    }

    /// Opens the app at `url` as soon as this copy of Decanter has quit.
    static func openWhenQuit(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", url.path]
        try? p.run()
    }
}
