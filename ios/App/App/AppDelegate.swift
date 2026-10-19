import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - ぷりんCut ネイティブ機能
import AVFoundation
import Photos
import PhotosUI
import Speech
import UniformTypeIdentifiers

/// 独自プラグインを登録するためのビューコントローラー（Main.storyboard から使う）
class PurinBridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(PurinNativePlugin())
    }
}

@objc(PurinNativePlugin)
public class PurinNativePlugin: CAPPlugin, CAPBridgedPlugin, PHPickerViewControllerDelegate {
    public let identifier = "PurinNativePlugin"
    public let jsName = "PurinNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "ping", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickVideo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveMedia", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteMedia", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "analyzeAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "transcribe", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "beginFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "appendFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveVideoToPhotos", returnType: CAPPluginReturnPromise)
    ]

    private var pickCall: CAPPluginCall?

    // MARK: 保存場所
    private func mediaDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func webURL(_ url: URL) -> String {
        return bridge?.portablePath(fromLocalURL: url)?.absoluteString ?? url.absoluteString
    }
    private func mediaURL(_ name: String) -> URL {
        return mediaDir().appendingPathComponent((name as NSString).lastPathComponent)
    }

    // MARK: 動画の情報
    private func videoInfo(_ url: URL, completion: @escaping ([String: Any]) -> Void) {
        let asset = AVURLAsset(url: url)
        Task {
            var info: [String: Any] = [:]
            do {
                let dur = try await asset.load(.duration)
                info["duration"] = CMTimeGetSeconds(dur)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let v = tracks.first {
                    let fps = try await v.load(.nominalFrameRate)
                    let size = try await v.load(.naturalSize)
                    let tf = try await v.load(.preferredTransform)
                    let r = CGRect(origin: .zero, size: size).applying(tf)
                    info["fps"] = Double(fps)
                    info["width"] = Double(abs(r.width))
                    info["height"] = Double(abs(r.height))
                }
                let at = try await asset.loadTracks(withMediaType: .audio)
                info["hasAudio"] = !at.isEmpty
            } catch {
                info["error"] = error.localizedDescription
            }
            completion(info)
        }
    }

    @objc func ping(_ call: CAPPluginCall) {
        call.resolve(["ok": true, "version": 2])
    }

    // MARK: 動画を選ぶ（写真アプリから無圧縮で取り込む）
    @objc func pickVideo(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .videos
            config.selectionLimit = 1
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            self.pickCall = call
            guard var top = self.bridge?.viewController else { call.reject("画面を開けませんでした"); return }
            while let p = top.presentedViewController { top = p }
            top.present(picker, animated: true)
        }
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let call = pickCall else { return }
        pickCall = nil
        guard let item = results.first?.itemProvider else {
            call.resolve(["cancelled": true]); return
        }
        let type = item.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .movie) == true }) ?? UTType.movie.identifier
        item.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            guard let url = url else {
                call.reject("動画を読み込めませんでした: \(error?.localizedDescription ?? "")"); return
            }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let name = UUID().uuidString + "." + ext
            let dest = self.mediaURL(name)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                call.reject("動画をコピーできませんでした: \(error.localizedDescription)"); return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.doubleValue ?? 0
            self.videoInfo(dest) { info in
                var r = info
                r["name"] = name
                r["displayName"] = item.suggestedName.map { $0 + "." + ext } ?? url.lastPathComponent
                r["url"] = self.webURL(dest)
                r["size"] = size
                call.resolve(r)
            }
        }
    }

    @objc func resolveMedia(_ call: CAPPluginCall) {
        guard let name = call.getString("name") else { call.reject("name がありません"); return }
        let u = mediaURL(name)
        if !FileManager.default.fileExists(atPath: u.path) { call.reject("動画ファイルが見つかりません"); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.doubleValue ?? 0
        call.resolve(["url": webURL(u), "size": size])
    }

    @objc func deleteMedia(_ call: CAPPluginCall) {
        if let name = call.getString("name") { try? FileManager.default.removeItem(at: mediaURL(name)) }
        call.resolve()
    }

    // MARK: 音声を16kHzモノラルで取り出す（波形・無音カット・文字起こし用）
    @objc func analyzeAudio(_ call: CAPPluginCall) {
        guard let name = call.getString("name") else { call.reject("name がありません"); return }
        let src = mediaURL(name)
        let rate = max(8000, min(48000, call.getInt("rate") ?? 16000))
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: src)
            let track = asset.tracks(withMediaType: .audio).first
            let fps = Double(asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0)
            guard let at = track else { call.reject("この動画には音声がありません"); return }
            do {
                let reader = try AVAssetReader(asset: asset)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let out = AVAssetReaderAudioMixOutput(audioTracks: [at], audioSettings: settings)
                out.alwaysCopiesSampleData = false
                reader.add(out)
                let dest = self.tmpDir().appendingPathComponent(name + ".\(rate).f32")
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                let fh = try FileHandle(forWritingTo: dest)
                defer { try? fh.close() }
                guard reader.startReading() else { throw reader.error ?? NSError(domain: "purin", code: 1) }
                var total = 0
                while let sb = out.copyNextSampleBuffer() {
                    if let bb = CMSampleBufferGetDataBuffer(sb) {
                        let len = CMBlockBufferGetDataLength(bb)
                        if len > 0 {
                            var d = Data(count: len)
                            let st = d.withUnsafeMutableBytes { raw -> OSStatus in
                                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
                            }
                            if st == kCMBlockBufferNoErr {
                                fh.write(d)
                                total += len
                            }
                        }
                    }
                }
                if reader.status == .failed { throw reader.error ?? NSError(domain: "purin", code: 2) }
                call.resolve(["url": self.webURL(dest), "sampleRate": rate, "samples": total / 4, "fps": fps])
            } catch {
                call.reject("音声を取り出せませんでした: \(error.localizedDescription)")
            }
        }
    }

    // MARK: 端末内の音声認識で文字起こし
    @objc func transcribe(_ call: CAPPluginCall) {
        guard let name = call.getString("name") else { call.reject("name がありません"); return }
        let from = call.getDouble("from") ?? 0
        let to = call.getDouble("to") ?? -1
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { call.reject("音声認識が許可されていません（設定アプリ → ぷりんCut で許可してください）"); return }
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), rec.isAvailable else {
                call.reject("日本語の音声認識が使えません"); return
            }
            let asset = AVURLAsset(url: self.mediaURL(name))
            Task {
                let total = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
                let end = to > 0 ? min(to, total) : total
                var segs: [[String: Any]] = []
                var t = max(0, from)
                let chunk = 50.0
                var idx = 0
                while t < end - 0.2 {
                    let len = min(chunk, end - t)
                    self.notifyListeners("transcribeProgress", data: ["done": t - from, "total": end - from])
                    if let part = await self.exportAudio(asset: asset, start: t, length: len, idx: idx) {
                        let r = await self.recognize(rec: rec, url: part)
                        for s in r {
                            segs.append(["text": s.0, "s": t + s.1, "e": t + s.1 + s.2])
                        }
                        try? FileManager.default.removeItem(at: part)
                    }
                    t += len
                    idx += 1
                }
                call.resolve(["segments": segs, "onDevice": rec.supportsOnDeviceRecognition])
            }
        }
    }

    private func exportAudio(asset: AVURLAsset, start: Double, length: Double, idx: Int) async -> URL? {
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let dest = tmpDir().appendingPathComponent("asr_\(idx)_\(UUID().uuidString).m4a")
        ex.outputURL = dest
        ex.outputFileType = .m4a
        ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ex.exportAsynchronously { c.resume() }
        }
        return ex.status == .completed ? dest : nil
    }

    private func recognize(rec: SFSpeechRecognizer, url: URL) async -> [(String, Double, Double)] {
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if #available(iOS 16, *) { req.addsPunctuation = true }
        return await withCheckedContinuation { (c: CheckedContinuation<[(String, Double, Double)], Never>) in
            var finished = false
            rec.recognitionTask(with: req) { result, error in
                if finished { return }
                if let r = result, r.isFinal {
                    finished = true
                    c.resume(returning: r.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) })
                } else if error != nil {
                    finished = true
                    c.resume(returning: [])
                }
            }
        }
    }

    // MARK: 書き出した動画を受け取ってカメラロールに保存
    private var writing: [String: FileHandle] = [:]

    @objc func beginFile(_ call: CAPPluginCall) {
        let name = (call.getString("name") ?? "export.mp4") as NSString
        let dest = tmpDir().appendingPathComponent(name.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else { call.reject("ファイルを作れませんでした"); return }
        writing[dest.lastPathComponent] = fh
        call.resolve(["id": dest.lastPathComponent])
    }

    @objc func appendFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let fh = writing[id], let b64 = call.getString("data"), let d = Data(base64Encoded: b64) else {
            call.reject("書き込みに失敗しました"); return
        }
        fh.write(d)
        call.resolve()
    }

    @objc func saveVideoToPhotos(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id がありません"); return }
        if let fh = writing[id] { try? fh.close(); writing[id] = nil }
        let url = tmpDir().appendingPathComponent(id)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                call.reject("写真への保存が許可されていません（設定アプリ → ぷりんCut → 写真 で許可してください）"); return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, error in
                try? FileManager.default.removeItem(at: url)
                if ok { call.resolve() } else { call.reject("カメラロールに保存できませんでした: \(error?.localizedDescription ?? "")") }
            }
        }
    }
}
