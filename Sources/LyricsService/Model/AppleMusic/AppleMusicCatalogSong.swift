import Foundation

/// One song from the Apple Music catalog, flattened to the fields the provider
/// needs. `name` / `artistName` are localized by the *storefront* they were
/// fetched from.
public struct AppleMusicCatalogSong: Sendable, Equatable {
    public let id: String
    public let name: String
    public let artistName: String
    public let albumName: String?
    public let isrc: String?
    public let durationInMillis: Int?

    public init(id: String, name: String, artistName: String, albumName: String? = nil, isrc: String? = nil, durationInMillis: Int? = nil) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.albumName = albumName
        self.isrc = isrc
        self.durationInMillis = durationInMillis
    }
}
