import Foundation
import LyricsService

/// A thin wrapper over the Apple Music catalog API, routed through the
/// `AppleMusicWebSession` (web player's `MusicKit` instance) so no
/// Apple-issued developer token is required.
///
/// The public `MusicDataRequest` transport is unavailable because
/// `dev.dongge0210.LyricsX` is not registered as a MusicKit client
/// identifier. The web player ships its own developer token; we
/// piggyback on that by calling `AppleMusicWebSession.shared.musicAPI()`.
@available(macOS 12.0, *)
public struct AppleMusicCatalog: Sendable {

    public init() {}

    /// The signed-in account's storefront id, e.g. `cn`, `tw`, `jp`.
    public func storefront() async throws -> String {
        let data = try await AppleMusicWebSession.shared.musicAPI("/v1/me/storefront")
        let wrapper = try JSONDecoder().decode(MusicKitWrapper<StorefrontResponse>.self, from: data)
        guard let id = wrapper.data.data.first?.id else {
            throw AppleMusicError.unexpectedResponse
        }
        return id
    }

    /// Search a storefront's catalog for songs matching a free-text term.
    public func search(
        term: String, storefront: String, limit: Int = 10
    ) async throws -> [AppleMusicCatalogSong] {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let path =
            "/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs&limit=\(limit)"
        let data = try await AppleMusicWebSession.shared.musicAPI(path)
        let wrapper = try JSONDecoder().decode(MusicKitWrapper<SearchResponse>.self, from: data)
        return (wrapper.data.results.songs?.data ?? []).map(\.flattened)
    }

    /// Look up a single catalog song by its adamID within a storefront.
    public func song(id: String, storefront: String) async throws -> AppleMusicCatalogSong {
        let data = try await AppleMusicWebSession.shared.musicAPI(
            "/v1/catalog/\(storefront)/songs/\(id)")
        let wrapper = try JSONDecoder().decode(MusicKitWrapper<SongListResponse>.self, from: data)
        guard let song = wrapper.data.data.first else {
            throw AppleMusicError.unexpectedResponse
        }
        return song.flattened
    }

    /// Look up catalog songs sharing an ISRC within a storefront.
    ///
    /// ISRC is the only storefront-independent key for a recording, so this is
    /// how Route B locates the same song in its native-script storefront.
    public func songs(isrc: String, storefront: String) async throws -> [AppleMusicCatalogSong] {
        let data = try await AppleMusicWebSession.shared.musicAPI(
            "/v1/catalog/\(storefront)/songs?filter[isrc]=\(isrc)")
        let wrapper = try JSONDecoder().decode(MusicKitWrapper<SongListResponse>.self, from: data)
        return wrapper.data.data.map(\.flattened)
    }
}

// MARK: - Apple Music API wire models

/// MusicKit's `music.api.music(path)` wraps every API response in `{"data": <payload>}`.
/// This generic wrapper strips that layer before the domain models decode the payload.
struct MusicKitWrapper<T: Decodable>: Decodable {
    let data: T
}

private struct StorefrontResponse: Decodable {
    let data: [Storefront]

    struct Storefront: Decodable {
        let id: String
    }
}

/// `GET .../songs` and `GET .../songs/{id}` both return `{ "data": [song] }`.
private struct SongListResponse: Decodable {
    let data: [CatalogSongResource]
}

/// `GET .../search` nests the songs under `results.songs.data`.
private struct SearchResponse: Decodable {
    let results: Results

    struct Results: Decodable {
        let songs: SongList?

        struct SongList: Decodable {
            let data: [CatalogSongResource]
        }
    }
}

private struct CatalogSongResource: Decodable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let isrc: String?
        let durationInMillis: Int?
    }

    var flattened: AppleMusicCatalogSong {
        AppleMusicCatalogSong(
            id: id,
            name: attributes.name,
            artistName: attributes.artistName,
            albumName: attributes.albumName,
            isrc: attributes.isrc,
            durationInMillis: attributes.durationInMillis)
    }
}
