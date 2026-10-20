import Flutter
import UIKit
import MediaPlayer
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var methodChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth, .defaultToSpeaker])
      try session.setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }

    application.beginReceivingRemoteControlEvents()

    if let registrar = self.registrar(forPlugin: "TryzubNowPlayingPlugin") {
      setupChannel(messenger: registrar.messenger())
    } else if let controller = (window?.rootViewController ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController) as? FlutterViewController {
      setupChannel(messenger: controller.binaryMessenger)
    }

    return result
  }

  private func setupChannel(messenger: FlutterBinaryMessenger) {
    if methodChannel != nil { return }
    let channel = FlutterMethodChannel(name: "com.tryzubmc.player/nowplaying", binaryMessenger: messenger)
    self.methodChannel = channel

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "updateNowPlaying" {
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        self?.updateNowPlaying(args: args)
        result(true)
      } else if call.method == "clearNowPlaying" {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    setupRemoteCommands()
  }

  private func setupRemoteCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.removeTarget(nil)
    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.methodChannel?.invokeMethod("onRemotePlay", arguments: nil)
      return .success
    }

    commandCenter.pauseCommand.isEnabled = true
    commandCenter.pauseCommand.removeTarget(nil)
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.methodChannel?.invokeMethod("onRemotePause", arguments: nil)
      return .success
    }

    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.removeTarget(nil)
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.methodChannel?.invokeMethod("onRemoteToggle", arguments: nil)
      return .success
    }

    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.nextTrackCommand.removeTarget(nil)
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      self?.methodChannel?.invokeMethod("onRemoteNext", arguments: nil)
      return .success
    }

    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.removeTarget(nil)
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      self?.methodChannel?.invokeMethod("onRemotePrev", arguments: nil)
      return .success
    }

    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
        self?.methodChannel?.invokeMethod("onRemoteSeek", arguments: positionEvent.positionTime)
        return .success
      }
      return .commandFailed
    }
  }

  private func updateNowPlaying(args: [String: Any]) {
    var nowPlayingInfo = [String: Any]()

    if let title = args["title"] as? String {
      nowPlayingInfo[MPMediaItemPropertyTitle] = title
    }
    if let artist = args["artist"] as? String {
      nowPlayingInfo[MPMediaItemPropertyArtist] = artist
    }
    if let duration = args["duration"] as? Double, duration > 0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    }
    if let position = args["position"] as? Double {
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
    }
    if let isPlaying = args["isPlaying"] as? Bool {
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }
    nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

    if let logo = UIImage(named: "Icon-App-1024x1024@1x") ?? UIImage(named: "AppIcon") {
      nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: logo.size) { _ in logo }
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

    if let coverUrlString = args["coverUrl"] as? String, !coverUrlString.isEmpty, let url = URL(string: coverUrlString) {
      URLSession.shared.dataTask(with: url) { data, response, error in
        guard let data = data, let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
          guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
          currentInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
          MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        }
      }.resume()
    }
  }
}
