import Flutter
import UIKit

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Bridges the Dart `promptlist/on_device_model` method channel to Apple's
/// on-device language model (Foundation Models, iOS 26+ with Apple
/// Intelligence).
///
/// Methods:
/// - `status` -> String availability
/// - `plan` {instructions, prompt} -> search criteria for the playlist
/// - `pick` {instructions, prompt} -> {songNumbers: [Int]}
final class OnDeviceModelPlugin: NSObject, FlutterPlugin {
  static let channelName = "promptlist/on_device_model"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(OnDeviceModelPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(FoundationModels)
      guard #available(iOS 26.0, *) else {
        result(call.method == "status" ? "unsupportedOS" : Self.unsupported())
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      let instructions = args["instructions"] as? String ?? ""
      let prompt = args["prompt"] as? String ?? ""

      switch call.method {
      case "status":
        result(OnDeviceModel.status())
      case "plan":
        Task { @MainActor in
          do {
            result(try await OnDeviceModel.plan(instructions: instructions, prompt: prompt))
          } catch {
            result(Self.flutterError(error))
          }
        }
      case "pick":
        Task { @MainActor in
          do {
            result(try await OnDeviceModel.pick(instructions: instructions, prompt: prompt))
          } catch {
            result(Self.flutterError(error))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    #else
      result(call.method == "status" ? "unsupportedOS" : Self.unsupported())
    #endif
  }

  private static func unsupported() -> FlutterError {
    FlutterError(
      code: "unsupported", message: "The on-device model needs iOS 26 or later.", details: nil)
  }

  private static func flutterError(_ error: Error) -> FlutterError {
    FlutterError(
      code: "generation_failed", message: error.localizedDescription,
      details: String(describing: error))
  }
}

#if canImport(FoundationModels)
  @available(iOS 26.0, *)
  @Generable
  struct PlaylistPlan {
    @Guide(description: "A short, evocative playlist title")
    var name: String

    @Guide(description: "One sentence describing the playlist")
    var summary: String

    @Guide(description: "Genres from the listener's genre list that fit the request")
    var genres: [String]

    @Guide(description: "Artists that clearly fit: ones named in the request, or from the listener's artist list")
    var artists: [String]

    @Guide(description: "Single words likely to appear in fitting song titles, such as rain or summer")
    var keywords: [String]

    @Guide(description: "Earliest release year that fits, or 0 for no limit")
    var fromYear: Int

    @Guide(description: "Latest release year that fits, or 0 for no limit")
    var toYear: Int

    @Guide(description: "Which songs to favor: mostPlayed, rarelyPlayed, or any")
    var listening: String
  }

  @available(iOS 26.0, *)
  @Generable
  struct SongPicks {
    @Guide(description: "Numbers of the chosen songs, in the order they should play")
    var songNumbers: [Int]
  }

  @available(iOS 26.0, *)
  enum OnDeviceModel {
    static func status() -> String {
      switch SystemLanguageModel.default.availability {
      case .available:
        return "available"
      case .unavailable(.deviceNotEligible):
        return "deviceNotEligible"
      case .unavailable(.appleIntelligenceNotEnabled):
        return "appleIntelligenceNotEnabled"
      case .unavailable(.modelNotReady):
        return "modelNotReady"
      case .unavailable:
        return "unavailable"
      @unknown default:
        return "unavailable"
      }
    }

    static func plan(instructions: String, prompt: String) async throws -> [String: Any] {
      let session = LanguageModelSession(instructions: instructions)
      let plan = try await session.respond(to: prompt, generating: PlaylistPlan.self).content
      return [
        "name": plan.name,
        "description": plan.summary,
        "genres": plan.genres,
        "artists": plan.artists,
        "keywords": plan.keywords,
        "fromYear": plan.fromYear,
        "toYear": plan.toYear,
        "listening": plan.listening,
      ]
    }

    static func pick(instructions: String, prompt: String) async throws -> [String: Any] {
      let session = LanguageModelSession(instructions: instructions)
      let picks = try await session.respond(to: prompt, generating: SongPicks.self).content
      return ["songNumbers": picks.songNumbers]
    }
  }
#endif
