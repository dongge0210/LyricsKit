import Foundation
import os
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
        Logger.AppleMusic.debug("storefront: \(id)")
        return id
    }

    /// Search a storefront's catalog for songs matching a free-text term.
    public func search(
        term: String, storefront: String, limit: Int = 10
    ) async throws -> [AppleMusicCatalogSong] {
        let encoded = term.addingPercentEncoding(
            withAllowedCharacters: {
                var cs = CharacterSet.urlQueryAllowed
                cs.remove(charactersIn: "&$+,\n#")
                return cs
            }()) ?? term
        let path =
            "/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs&limit=\(limit)"
        Logger.AppleMusic.debug("search term: \(term), storefront: \(storefront)")
        let data = try await AppleMusicWebSession.shared.musicAPI(path)
        do {
            let wrapper = try JSONDecoder().decode(MusicKitWrapper<SearchResponse>.self, from: data)
            let results = (wrapper.data.results.songs?.data ?? []).map(\.flattened)
            Logger.AppleMusic.debug("search returned \(results.count) songs")
            return results
        } catch {
            // Debug: dump raw response to figure out MusicKit's actual format
            if let raw = String(data: data, encoding: .utf8) {
                Logger.AppleMusic.debug("search decode failed, raw: \(String(raw.prefix(300)))…")
            }
            throw error
        }
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

/// MusicKit's `music.api.music(path)` generally wraps every API response in `{"data": <payload>}`.
/// However the web player's behavior can vary: sometimes the returned payload is already
/// the underlying API response object. This wrapper supports both the envelope form
/// and the direct payload form.
struct MusicKitWrapper<T: Decodable>: Decodable {
    let data: T

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            data = try container.decode(T.self, forKey: .data)
        } catch {
            data = try T(from: decoder)
        }
    }
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
