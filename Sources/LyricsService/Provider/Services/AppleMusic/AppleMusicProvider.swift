import Foundation
import LyricsCore
import os
import LyricsService

// MARK: - Apple Music Lyrics Provider

/// Fetches word-timed (syllable) lyrics from Apple Music via the internal
/// amp-api. The syllable-lyrics endpoint is NOT part of the public MusicKit
/// catalog API — it only responds to the web player's authenticated session
/// (page-level `MusicKit.getInstance().api.music()`). `MusicDataRequest`
/// returns HTML/401 on this path.
@available(macOS 12.0, *)
extension LyricsProviders {
    public final class AppleMusic {
        let httpClient: HTTPClient

        init(httpClient: HTTPClient = URLSessionHTTPClient.shared) {
            self.httpClient = httpClient
        }
    }
}

// MARK: - _LyricsProvider

@available(macOS 12.0, *)
extension LyricsProviders.AppleMusic: _LyricsProvider {

    public struct LyricsToken: Sendable {
        public let song: AppleMusicCatalogSong
    }

    public static let service: String = "Apple Music"

    public func search(for request: LyricsSearchRequest) async throws -> [LyricsToken] {
        let catalog = AppleMusicCatalog()
        let storefront: String
        if let override = AppleMusicWebSession.shared.storefrontOverride {
            storefront = override
        } else {
            storefront = try await catalog.storefront()
        }

        let searchTerm: String
        let filterArtist: String?
        switch request.searchTerm {
        case .keyword(let keyword):
            searchTerm = keyword
            filterArtist = nil
        case .info(let title, let artist):
            searchTerm = title
            filterArtist = artist.lowercased()
        }

        Logger.AppleMusic.debug("search request: term=\(searchTerm) artistFilter=\(filterArtist ?? "none")")
        let songs = try await catalog.search(term: searchTerm, storefront: storefront)
        let filtered = filterArtist.map { artist in
            songs.filter { $0.artistName.lowercased().contains(artist) || artist.contains($0.artistName.lowercased()) }
        } ?? songs
        Logger.AppleMusic.debug("provider search: \(songs.count) raw → \(filtered.count) filtered tokens")
        return filtered.map { LyricsToken(song: $0) }
    }

    public func fetch(with token: LyricsToken) async throws -> Lyrics {
        let catalog = AppleMusicCatalog()
        let storefront: String
        if let override = AppleMusicWebSession.shared.storefrontOverride {
            storefront = override
        } else {
            storefront = try await catalog.storefront()
        }
        let songID = token.song.id
        // Apple Music requires &l=<lang> to include translations in the TTML response.
        // Without it, <translations/> is always empty. Use override or system language.
        let lang = AppleMusicWebSession.shared.languageOverride
            ?? (Locale.preferredLanguages.first?.prefix(5))
            ?? "zh-Hans"
        let path = "/v1/catalog/\(storefront)/songs/\(songID)/syllable-lyrics?l=\(lang)&extend=ttmlLocalizations"
        Logger.AppleMusic.debug("fetch lyrics: \(token.song.name) (id=\(songID)) lang=\(lang) storefront=\(storefront)")

        let data: Data
        do {
            data = try await AppleMusicWebSession.shared.musicAPI(path)
        } catch {
            Logger.AppleMusic.error("musicAPI failed: \(error.localizedDescription)")
            throw LyricsProviderError.processingFailed(
                reason: "Apple Music amp-api request failed: \(error.localizedDescription)"
            )
        }

        let response: TTMLLyricsResponse
        do {
            let wrapper = try JSONDecoder().decode(MusicKitWrapper<TTMLLyricsResponse>.self, from: data)
            response = wrapper.data
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                Logger.AppleMusic.error("TTML decode failed, raw: \(String(raw.prefix(200)))")
            }
            throw LyricsProviderError.processingFailed(
                reason: "Failed to decode TTML response: \(error.localizedDescription)"
            )
        }

        guard let ttml = response.data.first?.attributes.ttmlLocalizations, !ttml.isEmpty else {
            throw LyricsProviderError.processingFailed(
                reason: "No syllable lyrics available for this track."
            )
        }

        guard let lyrics = Lyrics(ttmlContent: ttml) else {
            throw LyricsProviderError.processingFailed(
                reason: "Failed to parse TTML lyrics for track \(songID)"
            )
        }

        // Reject if no lines have timing data (all positions zero + no timetag)
        let hasLinesWithTime = lyrics.lines.contains { line in
            line.position != 0 || line.attachments.timetag != nil
        }
        guard hasLinesWithTime else {
            throw LyricsProviderError.processingFailed(
                reason: "No syllable lyrics available for this track."
            )
        }

        Logger.AppleMusic.debug("lyrics fetched & parsed OK")

        lyrics.applyMetadata(
            title: token.song.name,
            artist: token.song.artistName,
            album: token.song.albumName,
            length: token.song.durationInMillis.map { Double($0) / 1000.0 },
            serviceToken: token.song.id
        )

        return lyrics
    }
}

// MARK: - amp-api TTML Response Model

private struct TTMLLyricsResponse: Decodable {
    let data: [Item]

    struct Item: Decodable {
        let attributes: Attributes

        struct Attributes: Decodable {
            let ttmlLocalizations: String
        }
    }
}

// MARK: - Service Registration

@available(macOS 12.0, *)
extension LyricsProviders.Service where Options == LyricsProviders.EmptyOptions {
    public static let appleMusic = Self(
        id: .appleMusic,
        factory: { _, http in LyricsProviders.AppleMusic(httpClient: http) }
    )
}
