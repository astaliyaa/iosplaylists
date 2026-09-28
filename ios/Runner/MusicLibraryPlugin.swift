import Flutter
import MusicKit
import UIKit

/// Bridges the Dart `promptlist/music_library` method channel to MusicKit.
///
/// Methods:
/// - `authorizationStatus` / `requestAuthorization` -> String status
/// - `fetchSongs` -> [[String: Any]] with one entry per library song
/// - `createPlaylist` {name, description, songIds} -> String playlist ID
final class MusicLibraryPlugin: NSObject, FlutterPlugin {
  static let channelName = "promptlist/music_library"

  /// Songs from the most recent library fetch, keyed by their library ID, so a
  /// playlist can be built from the IDs Dart sends back. Only touched on the
  /// main actor.
  private var songsByID: [String: Song] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MusicLibraryPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorizationStatus":
      result(Self.describe(MusicAuthorization.currentStatus))

    case "requestAuthorization":
      Task { @MainActor in
        let status = await MusicAuthorization.request()
        result(Self.describe(status))
      }

    case "fetchSongs":
      Task { @MainActor in
        do {
          let songs = try await self.loadLibrarySongs()
          result(songs.map(Self.encode))
        } catch {
          result(Self.flutterError("fetch_failed", error))
        }
      }

    case "createPlaylist":
      guard let args = call.arguments as? [String: Any],
        let name = args["name"] as? String,
        let songIDs = args["songIds"] as? [String]
      else {
        result(
          FlutterError(
            code: "bad_arguments", message: "createPlaylist needs name and songIds",
            details: nil))
        return
      }
      let description = args["description"] as? String
      Task { @MainActor in
        do {
          let playlistID = try await self.createPlaylist(
            name: name, description: description, songIDs: songIDs)
          result(playlistID)
        } catch {
          result(Self.flutterError("create_failed", error))
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Library access

  @MainActor
  private func loadLibrarySongs() async throws -> [Song] {
    let request = MusicLibraryRequest<Song>()
    let response = try await request.response()

    var batch = response.items
    var songs = Array(batch)
    while batch.hasNextBatch, let next = try await batch.nextBatch() {
      songs.append(contentsOf: next)
      batch = next
    }

    songsByID = Dictionary(
      songs.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
    return songs
  }

  @MainActor
  private func createPlaylist(
    name: String, description: String?, songIDs: [String]
  ) async throws -> String {
    if songIDs.contains(where: { songsByID[$0] == nil }) {
      // The cache is empty or stale (e.g. the library changed); reload it once.
      _ = try await loadLibrarySongs()
    }
    let songs = songIDs.compactMap { songsByID[$0] }
    guard !songs.isEmpty else {
      throw PlaylistError.noMatchingSongs
    }

    let playlist = try await MusicLibrary.shared.createPlaylist(
      name: name,
      description: description,
      authorDisplayName: nil,
      items: songs)
    return playlist.id.rawValue
  }

  // MARK: - Encoding

  private static func encode(_ song: Song) -> [String: Any] {
    var map: [String: Any] = [
      "id": song.id.rawValue,
      "title": song.title,
      "artist": song.artistName,
      "genres": song.genreNames,
      "playCount": song.playCount ?? 0,
      "explicit": song.contentRating == .explicit,
    ]
    if let album = song.albumTitle { map["album"] = album }
    if let date = song.releaseDate {
      map["year"] = Calendar(identifier: .gregorian).component(.year, from: date)
    }
    if let track = song.trackNumber { map["trackNumber"] = track }
    if let disc = song.discNumber { map["discNumber"] = disc }
    if let duration = song.duration { map["durationSeconds"] = Int(duration) }
    if let added = song.libraryAddedDate { map["dateAddedMs"] = milliseconds(added) }
    if let played = song.lastPlayedDate { map["lastPlayedMs"] = milliseconds(played) }
    return map
  }

  private static func milliseconds(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970 * 1000)
  }

  private static func describe(_ status: MusicAuthorization.Status) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "denied"
    }
  }

  private static func flutterError(_ code: String, _ error: Error) -> FlutterError {
    FlutterError(code: code, message: error.localizedDescription, details: String(describing: error))
  }
}

private enum PlaylistError: LocalizedError {
  case noMatchingSongs

  var errorDescription: String? {
    switch self {
    case .noMatchingSongs:
      return "None of the chosen songs are in your library anymore."
    }
  }
}
