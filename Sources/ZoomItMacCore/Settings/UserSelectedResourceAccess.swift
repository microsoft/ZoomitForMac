import Foundation

enum UserSelectedResource: String, CaseIterable {
    case breakSound
    case breakBackground
    case snipDirectory
}

enum UserSelectedResourceAccessError: LocalizedError {
    case missingAuthorization(UserSelectedResource)
    case invalidBookmark(UserSelectedResource)

    var errorDescription: String? {
        switch self {
        case .missingAuthorization:
            return "ZoomIt no longer has access to the selected file or folder. Choose it again in Settings."
        case .invalidBookmark:
            return "ZoomIt could not restore access to the selected file or folder. Choose it again in Settings."
        }
    }
}

@MainActor
protocol UserSelectedResourceAccess: AnyObject {
    func saveSelection(_ url: URL, for resource: UserSelectedResource) throws
    func withAccess<T>(
        to resource: UserSelectedResource,
        legacyPath: String,
        operation: (URL) throws -> T
    ) throws -> T
}

@MainActor
final class UserDefaultsUserSelectedResourceAccess: UserSelectedResourceAccess {
    private let defaults: UserDefaults
    private let keyPrefix = "userSelectedResourceBookmark."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveSelection(_ url: URL, for resource: UserSelectedResource) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key(for: resource))
    }

    func withAccess<T>(
        to resource: UserSelectedResource,
        legacyPath: String,
        operation: (URL) throws -> T
    ) throws -> T {
        if let data = defaults.data(forKey: key(for: resource)) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let startedAccess = url.startAccessingSecurityScopedResource()
                if DistributionChannel.isAppStore && !startedAccess {
                    throw UserSelectedResourceAccessError.invalidBookmark(resource)
                }
                defer {
                    if startedAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if isStale {
                    try saveSelection(url, for: resource)
                }
                return try operation(url)
            } catch let error as UserSelectedResourceAccessError {
                throw error
            } catch {
                if DistributionChannel.isAppStore {
                    throw error
                }
            }
        }

        guard !DistributionChannel.isAppStore else {
            throw UserSelectedResourceAccessError.missingAuthorization(resource)
        }

        let trimmedPath = legacyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw UserSelectedResourceAccessError.missingAuthorization(resource)
        }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        return try operation(URL(fileURLWithPath: expandedPath))
    }

    private func key(for resource: UserSelectedResource) -> String {
        keyPrefix + resource.rawValue
    }
}