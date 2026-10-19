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
        // 映像はWebの後ろに置いたネイティブのプレーヤーで表示するため、Webの背景を透明にする
        webView?.isOpaque = false
        webView?.backgroundColor = .clear
        webView?.scrollView.backgroundColor = .clear
        webView?.layer.backgroundColor = UIColor(red: 1, green: 0.973, blue: 0.863, alpha: 1).cgColor
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
        CAPPluginMethod(name: "saveVideoToPhotos", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerSetProject", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerRect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerPlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerPause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerSeek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerTime", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playerVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBackground", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exportStart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exportStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exportCancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearTemp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "audioFX", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "audioFXStatus", returnType: CAPPluginReturnPromise)
    ]
    var fxProgress: [String: Double] = [:]
    let purinPlayer = PurinPlayer()
    let purinExporter = PurinExporter()
    func tmpFileURL(_ name: String) -> URL { tmpDir().appendingPathComponent((name as NSString).lastPathComponent) }
    func closeWriting(_ id: String) { if let fh = writing[id] { try? fh.close(); writing[id] = nil } }

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

// MARK: - プレビュー再生（iMovieと同じAVFoundationの仕組み）
extension PurinNativePlugin {
    @objc func playerSetProject(_ call: CAPPluginCall) {
        guard let obj = call.options as? [String: Any] else { call.reject("データがありません"); return }
        purinPlayer.setProject(obj, mediaURL: { self.mediaURL($0) }) { err in
            if let e = err { call.reject(e) } else { call.resolve() }
        }
    }
    @objc func playerRect(_ call: CAPPluginCall) {
        let x = call.getDouble("x") ?? 0, y = call.getDouble("y") ?? 0, w = call.getDouble("w") ?? 0, h = call.getDouble("h") ?? 0
        let vis = call.getBool("visible") ?? false
        DispatchQueue.main.async {
            if let wv = self.bridge?.webView { self.purinPlayer.attach(to: wv) }
            self.purinPlayer.setRect(CGRect(x: x, y: y, width: w, height: h), visible: vis)
            call.resolve()
        }
    }
    @objc func playerPlay(_ call: CAPPluginCall) {
        let t = call.getDouble("t") ?? 0
        purinPlayer.play(from: t) { call.resolve(["t": $0]) }
    }
    @objc func playerPause(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["t": self.purinPlayer.pause()]) }
    }
    @objc func playerSeek(_ call: CAPPluginCall) {
        purinPlayer.seek(call.getDouble("t") ?? 0)
        call.resolve()
    }
    @objc func playerTime(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["t": self.purinPlayer.currentTime, "playing": self.purinPlayer.isPlaying]) }
    }
    @objc func playerVolume(_ call: CAPPluginCall) {
        purinPlayer.setVolume(Float(call.getDouble("v") ?? 1))
        call.resolve()
    }
    @objc func setBackground(_ call: CAPPluginCall) {
        let hex = (call.getString("color") ?? "#fff8dc").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        let c = UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        DispatchQueue.main.async { self.bridge?.webView?.layer.backgroundColor = c.cgColor; call.resolve() }
    }
}

/// 編集内容（区間・レイアウト・色調）をAVMutableCompositionとCore Imageで再現して再生する
final class PurinPlayer {
    let player = AVPlayer()
    private var layer: AVPlayerLayer?
    private var assets: [String: AVURLAsset] = [:]
    private var seeking = false
    private var pendingSeek: Double?
    private var audioTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var volume: Float = 1
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private(set) var isPlaying = false
    var currentTime: Double { CMTimeGetSeconds(player.currentTime()) }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
    }

    func attach(to wv: UIView) {
        if layer != nil { return }
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspect
        l.backgroundColor = UIColor.black.cgColor
        l.isHidden = true
        wv.layer.insertSublayer(l, at: 0)
        layer = l
    }

    func setRect(_ r: CGRect, visible: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.frame = r
        layer?.isHidden = !visible || r.width < 2
        CATransaction.commit()
    }

    func setVolume(_ v: Float) {
        volume = v
        DispatchQueue.main.async { self.applyMix(self.player.currentItem) }
    }

    private func applyMix(_ item: AVPlayerItem?) {
        guard let item = item, audioTrackID != kCMPersistentTrackID_Invalid,
              let t = item.asset.track(withTrackID: audioTrackID) else { return }
        let p = AVMutableAudioMixInputParameters(track: t)
        p.setVolume(volume, at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [p]
        item.audioMix = mix
    }

    private static func ct(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 60000) }

    func setProject(_ o: [String: Any], mediaURL: @escaping (String) -> URL, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let W = CGFloat((o["W"] as? NSNumber)?.doubleValue ?? 1080), H = CGFloat((o["H"] as? NSNumber)?.doubleValue ?? 1920)
            let fps = max(1, (o["fps"] as? NSNumber)?.doubleValue ?? 30)
            let pieces = o["pieces"] as? [[String: Any]] ?? []
            let built: BuiltComp
            do { built = try purinBuildComposition(o, assets: &self.assets, mediaURL: mediaURL) } catch { done("合成できません: \(error.localizedDescription)"); return }
            let comp = built.comp, transform: CGAffineTransform? = built.transform, natural = built.natural
            self.audioTrackID = built.audioID
            let spec = RenderSpec(o, W: W, H: H, natural: natural, transform: transform ?? .identity)
            let vc = AVMutableVideoComposition(asset: comp) { req in
                let out = spec.render(req.sourceImage, time: CMTimeGetSeconds(req.compositionTime))
                req.finish(with: out, context: nil)
            }
            vc.renderSize = CGSize(width: W, height: H)
            vc.frameDuration = purinFrameDuration(fps)
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = vc
            DispatchQueue.main.async {
                let keep = self.currentTime
                self.applyMix(item)
                self.player.replaceCurrentItem(with: item)
                self.player.seek(to: PurinPlayer.ct(keep), toleranceBefore: .zero, toleranceAfter: .zero)
                if self.isPlaying { self.player.play() }
                done(nil)
            }
        }
    }

    func play(from t: Double, done: @escaping (Double) -> Void) {
        DispatchQueue.main.async {
            self.isPlaying = true
            self.player.seek(to: PurinPlayer.ct(t), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    guard self.isPlaying else { done(self.currentTime); return }
                    self.player.playImmediately(atRate: 1)
                    done(self.currentTime)
                }
            }
        }
    }

    func pause() -> Double {
        isPlaying = false
        player.pause()
        return currentTime
    }

    func seek(_ t: Double) {
        DispatchQueue.main.async {
            if self.seeking { self.pendingSeek = t; return }
            self.seeking = true
            self.player.seek(to: PurinPlayer.ct(t), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    self.seeking = false
                    if let n = self.pendingSeek { self.pendingSeek = nil; self.seek(n) }
                }
            }
        }
    }
}

/// レイアウト（ぼかし背景・切り抜きレイヤー）と色調補正をCore Imageで描く
struct RenderSpec {
    struct Layer { let crop: CGRect; let w, cx, cy, radius, border: CGFloat; let bc: CIColor; let fx: Bool }
    struct Adj { let t0, t1: Double; let br, exp, ct, sat, hue, temp: Double }
    struct Zoom { let t0, t1: Double; let z, x, y: Double }
    let W, H: CGFloat
    let blur: Bool
    let dark: CGFloat
    let layers: [Layer]
    let adjs: [Adj]
    let zooms: [Zoom]
    let orient: CGImagePropertyOrientation?
    let natural: CGSize

    init(_ o: [String: Any], W: CGFloat, H: CGFloat, natural: CGSize, transform: CGAffineTransform) {
        self.W = W; self.H = H; self.natural = natural
        let lay = o["layout"] as? [String: Any] ?? [:]
        blur = (lay["bg"] as? String) == "blur"
        dark = CGFloat((lay["bgDark"] as? NSNumber)?.doubleValue ?? 0.3)
        var ls: [Layer] = []
        for l in lay["layers"] as? [[String: Any]] ?? [] {
            if (l["on"] as? Bool) == false { continue }
            let c = l["crop"] as? [String: Any] ?? [:]
            func n(_ d: [String: Any], _ k: String, _ v: Double) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? v) }
            let hex = ((l["bc"] as? String) ?? "#ffffff").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            var v: UInt64 = 0; Scanner(string: hex).scanHexInt64(&v)
            ls.append(Layer(crop: CGRect(x: n(c, "x", 0), y: n(c, "y", 0), width: n(c, "w", 1), height: n(c, "h", 1)),
                            w: n(l, "w", 1), cx: n(l, "cx", 0.5), cy: n(l, "cy", 0.5), radius: n(l, "radius", 0), border: n(l, "border", 0),
                            bc: CIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255),
                            fx: (l["fx"] as? Bool) ?? false))
        }
        layers = ls
        var as_: [Adj] = []
        for a in o["adj"] as? [[String: Any]] ?? [] {
            func d(_ k: String) -> Double { (a[k] as? NSNumber)?.doubleValue ?? 0 }
            as_.append(Adj(t0: d("t0"), t1: d("t1"), br: d("br"), exp: d("exp"), ct: d("ct"), sat: d("sat"), hue: d("hue"), temp: d("temp")))
        }
        adjs = as_
        var zs: [Zoom] = []
        for a in o["zoom"] as? [[String: Any]] ?? [] {
            func d(_ k: String, _ v: Double) -> Double { (a[k] as? NSNumber)?.doubleValue ?? v }
            zs.append(Zoom(t0: d("t0", 0), t1: d("t1", 0), z: max(1, d("z", 1)), x: d("x", 0), y: d("y", 0)))
        }
        zooms = zs
        // 回転情報（縦撮影など）
        let a = transform.a, b = transform.b
        if abs(a) < 0.01 && b > 0.5 { orient = .right } else if abs(a) < 0.01 && b < -0.5 { orient = .left } else if a < -0.5 { orient = .down } else { orient = nil }
    }

    private func adjust(_ img: CIImage, _ a: Adj?, fx: Bool) -> CIImage {
        var br = 1.0, ct = 1.0, sat = 1.0, ev = 0.0, hue = 0.0, temp = 0.0
        if let a = a { br = 1 + a.br / 100; ev = a.exp / 100; ct = 1 + a.ct / 100; sat = max(0, 1 + a.sat / 100); hue = a.hue * .pi / 180; temp = a.temp / 100 }
        if fx { br *= 1.14; ct += 0.06; sat += 0.1 }
        var o = img
        let evAll = log2(max(0.01, br)) + ev
        if abs(evAll) > 0.001 { o = o.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: evAll]) }
        if abs(ct - 1) > 0.001 || abs(sat - 1) > 0.001 { o = o.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: ct, kCIInputSaturationKey: sat, kCIInputBrightnessKey: 0]) }
        if abs(hue) > 0.001 { o = o.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue]) }
        if abs(temp) > 0.001 { o = o.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: CGFloat(0.10 * temp), y: CGFloat(0.03 * temp), z: CGFloat(-0.10 * temp), w: 0)]) }
        return o
    }

    func render(_ source: CIImage, time: Double) -> CIImage {
        var src = source
        // 回転がまだ反映されていなければここで回す
        if let o = orient, abs(src.extent.width - natural.width) < 1, abs(src.extent.height - natural.height) < 1, natural.width != natural.height {
            src = src.oriented(o)
        }
        src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        let vw = src.extent.width, vh = src.extent.height
        // ズーム（元の映像を拡大して、見せる位置をずらす）
        if let zm = zooms.first(where: { time >= $0.t0 - 0.0005 && time < $0.t1 }), zm.z > 1.001 {
            let z = CGFloat(zm.z), zw = vw / z, zh = vh / z
            let cx = vw / 2 + CGFloat(zm.x) * (vw - zw) / 2, cyTop = vh / 2 + CGFloat(zm.y) * (vh - zh) / 2
            let r = CGRect(x: cx - zw / 2, y: vh - (cyTop + zh / 2), width: zw, height: zh)
            src = src.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY)).transformed(by: CGAffineTransform(scaleX: z, y: z))
        }
        let a = adjs.first { time >= $0.t0 - 0.0005 && time < $0.t1 }
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        var out = CIImage(color: .black).cropped(to: full)
        if vw < 2 || vh < 2 { return out }
        let base = adjust(src, a, fx: false)
        if blur {
            let s = max(W / vw, H / vh) * 0.1
            let small = base.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let bl = small.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).cropped(to: small.extent)
            let up = bl.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            let dx = (W - up.extent.width) / 2 - up.extent.minX, dy = (H - up.extent.height) / 2 - up.extent.minY
            let bg = up.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1 - dark, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - dark, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1 - dark, w: 0)])
                .cropped(to: full)
            out = bg.composited(over: out)
        }
        for L in layers {
            let img = L.fx ? adjust(src, a, fx: true) : base
            // Webの座標（左上原点）→ Core Image（左下原点）
            let cr = CGRect(x: L.crop.minX * vw, y: vh * (1 - L.crop.minY - L.crop.height), width: max(2, L.crop.width * vw), height: max(2, L.crop.height * vh))
            let dw = L.w * W, sc = dw / cr.width, dh = cr.height * sc
            let x = L.cx * W - dw / 2, yTop = L.cy * H - dh / 2, y = H - yTop - dh
            var piece = img.cropped(to: cr).transformed(by: CGAffineTransform(translationX: -cr.minX, y: -cr.minY))
                .transformed(by: CGAffineTransform(scaleX: sc, y: sc)).transformed(by: CGAffineTransform(translationX: x, y: y))
            let rect = CGRect(x: x, y: y, width: dw, height: dh)
            let rad = min(L.radius, dw / 2, dh / 2)
            if rad > 0, let g = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": rad, "inputColor": CIColor.white]), let mask = g.outputImage {
                piece = piece.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
            }
            if L.border > 0, let g = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect.insetBy(dx: -L.border / 2, dy: -L.border / 2)), "inputRadius": rad + L.border / 2, "inputColor": L.bc]), let b = g.outputImage {
                out = b.composited(over: out)
            }
            out = piece.composited(over: out)
        }
        return out.cropped(to: full)
    }
}


// MARK: - 合成（再生と書き出しで共通）
struct BuiltComp { let comp: AVMutableComposition; let audioID: CMPersistentTrackID; let transform: CGAffineTransform; let natural: CGSize }
func purinCT(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 60000) }
func purinFrameDuration(_ fps: Double) -> CMTime {
    if abs(fps - fps.rounded()) > 0.01 { return CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded())) }
    return CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
}
func purinBuildComposition(_ o: [String: Any], assets: inout [String: AVURLAsset], mediaURL: (String) -> URL) throws -> BuiltComp {
    let pieces = o["pieces"] as? [[String: Any]] ?? []
    let comp = AVMutableComposition()
    guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NSError(domain: "purin", code: 10, userInfo: [NSLocalizedDescriptionKey: "映像トラックを作れません"]) }
    let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    var transform: CGAffineTransform?
    var natural = CGSize(width: 1080, height: 1920)
    for p in pieces {
        guard let name = p["name"] as? String else { continue }
        let s = (p["s"] as? NSNumber)?.doubleValue ?? 0, e = (p["e"] as? NSNumber)?.doubleValue ?? 0, t = (p["t"] as? NSNumber)?.doubleValue ?? 0
        if e - s < 0.001 { continue }
        let asset: AVURLAsset
        if let a = assets[name] { asset = a } else { asset = AVURLAsset(url: mediaURL(name), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]); assets[name] = asset }
        guard let sv = asset.tracks(withMediaType: .video).first else { continue }
        // 音声補正（コンプ・ノイズ除去・BGM除去）済みの音声があればそちらを使う
        var audioSrc: AVAssetTrack? = asset.tracks(withMediaType: .audio).first
        if let procs = o["audioFiles"] as? [String: String], let pf = procs[name] {
            let key = "proc:" + pf
            let pa: AVURLAsset
            if let a = assets[key] { pa = a } else { pa = AVURLAsset(url: purinCacheURL(pf), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]); assets[key] = pa }
            if let t = pa.tracks(withMediaType: .audio).first { audioSrc = t }
        }
        if transform == nil { transform = sv.preferredTransform; natural = sv.naturalSize }
        let at0 = purinCT(t)
        let end = vt.timeRange.end
        if CMTimeCompare(at0, end) > 0 { vt.insertEmptyTimeRange(CMTimeRange(start: end, end: at0)) }
        let range = CMTimeRange(start: purinCT(s), end: purinCT(e))
        try vt.insertTimeRange(range, of: sv, at: vt.timeRange.end)
        if let at = at {
            let aend = at.timeRange.end
            if CMTimeCompare(at0, aend) > 0 { at.insertEmptyTimeRange(CMTimeRange(start: aend, end: at0)) }
            if let sa = audioSrc {
                try at.insertTimeRange(range, of: sa, at: at.timeRange.end)
            } else {
                at.insertEmptyTimeRange(CMTimeRange(start: at.timeRange.end, duration: range.duration))
            }
        }
    }
    // 最後の空白（テロップだけの部分など）も長さに含める
    if let dur = (o["dur"] as? NSNumber)?.doubleValue {
        let want = purinCT(dur), end = vt.timeRange.end
        if CMTimeCompare(want, end) > 0 { vt.insertEmptyTimeRange(CMTimeRange(start: end, end: want)) }
    }
    if let tf = transform { vt.preferredTransform = tf }
    return BuiltComp(comp: comp, audioID: at?.trackID ?? kCMPersistentTrackID_Invalid, transform: transform ?? .identity, natural: natural)
}

// MARK: - 書き出し（iPhoneの動画エンジンで合成・エンコードし、カメラロールへ保存）
final class PurinExporter {
    private(set) var state = "idle"
    private(set) var message = ""
    private var session: AVAssetExportSession?
    private var assets: [String: AVURLAsset] = [:]
    var progress: Double { state == "running" ? Double(session?.progress ?? 0) : (state == "idle" ? 0 : 1) }

    func cancel() { session?.cancelExport(); state = "cancelled" }

    func start(_ o: [String: Any], mediaURL: @escaping (String) -> URL, tmpURL: @escaping (String) -> URL) {
        state = "running"; message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let built = try purinBuildComposition(o, assets: &self.assets, mediaURL: mediaURL)
                let comp = built.comp
                let W = CGFloat((o["W"] as? NSNumber)?.doubleValue ?? 1080), H = CGFloat((o["H"] as? NSNumber)?.doubleValue ?? 1920)
                let RW = CGFloat((o["renderW"] as? NSNumber)?.doubleValue ?? Double(W)), RH = CGFloat((o["renderH"] as? NSNumber)?.doubleValue ?? Double(H))
                let fps = max(1, (o["fps"] as? NSNumber)?.doubleValue ?? 30)
                // 効果音・BGMを混ぜた音声（Web側で作ったWAV）
                var extraID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
                if let ex = o["extraAudio"] as? String {
                    let a = AVURLAsset(url: tmpURL(ex))
                    if let src = a.tracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        let len = CMTimeMinimum(a.duration, comp.duration)
                        try t.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: src, at: .zero)
                        extraID = t.trackID
                    }
                }
                // テロップ・画像（Web側で描いた透明PNG）
                struct Ov { let t0: Double; let t1: Double; let url: URL }
                let ovs: [Ov] = (o["overlays"] as? [[String: Any]] ?? []).compactMap {
                    guard let f = $0["file"] as? String else { return nil }
                    return Ov(t0: ($0["t0"] as? NSNumber)?.doubleValue ?? 0, t1: ($0["t1"] as? NSNumber)?.doubleValue ?? 0, url: tmpURL(f))
                }
                let cache = NSCache<NSURL, CIImage>(); cache.countLimit = 6
                let spec = RenderSpec(o, W: W, H: H, natural: built.natural, transform: built.transform)
                let k = RW / W
                let vc = AVMutableVideoComposition(asset: comp) { req in
                    let t = CMTimeGetSeconds(req.compositionTime)
                    var out = spec.render(req.sourceImage, time: t).transformed(by: CGAffineTransform(scaleX: k, y: k))
                    // 二分探索で今の時刻のテロップ画像を探す
                    var lo = 0, hi = ovs.count - 1, hit: Ov?
                    while lo <= hi { let m = (lo + hi) / 2; if ovs[m].t1 <= t { lo = m + 1 } else if ovs[m].t0 > t { hi = m - 1 } else { hit = ovs[m]; break } }
                    if let h = hit {
                        var img = cache.object(forKey: h.url as NSURL)
                        if img == nil, let i = CIImage(contentsOf: h.url) { img = i; cache.setObject(i, forKey: h.url as NSURL) }
                        if let i = img { out = i.composited(over: out) }
                    }
                    req.finish(with: out.cropped(to: CGRect(x: 0, y: 0, width: RW, height: RH)), context: nil)
                }
                vc.renderSize = CGSize(width: RW, height: RH)
                vc.frameDuration = purinFrameDuration(fps)
                let mix = AVMutableAudioMix(); var params: [AVMutableAudioMixInputParameters] = []
                if built.audioID != kCMPersistentTrackID_Invalid, let t = comp.track(withTrackID: built.audioID) {
                    let p = AVMutableAudioMixInputParameters(track: t); p.setVolume(Float((o["origVol"] as? NSNumber)?.doubleValue ?? 1), at: .zero); params.append(p)
                }
                if extraID != kCMPersistentTrackID_Invalid, let t = comp.track(withTrackID: extraID) {
                    let p = AVMutableAudioMixInputParameters(track: t); p.setVolume(1, at: .zero); params.append(p)
                }
                mix.inputParameters = params
                let preset = RW * RH > 1280 * 720 * 1.1 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHighestQuality
                guard let ses = AVAssetExportSession(asset: comp, presetName: preset) else { throw NSError(domain: "purin", code: 11, userInfo: [NSLocalizedDescriptionKey: "書き出しを開始できません"]) }
                let out = tmpURL("purincut_export_\(Int(Date().timeIntervalSince1970)).mp4")
                try? FileManager.default.removeItem(at: out)
                ses.outputURL = out
                ses.outputFileType = .mp4
                ses.videoComposition = vc
                ses.audioMix = mix
                ses.shouldOptimizeForNetworkUse = true
                self.session = ses
                ses.exportAsynchronously {
                    if ses.status == .completed {
                        self.state = "saving"
                        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                            guard st == .authorized || st == .limited else { self.state = "failed"; self.message = "写真への保存が許可されていません（設定アプリ → ぷりんCut → 写真）"; return }
                            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out) }) { ok, err in
                                try? FileManager.default.removeItem(at: out)
                                if ok { self.state = "saved" } else { self.state = "failed"; self.message = err?.localizedDescription ?? "保存できませんでした" }
                            }
                        }
                    } else if ses.status == .cancelled {
                        self.state = "cancelled"
                    } else {
                        self.state = "failed"; self.message = ses.error?.localizedDescription ?? "書き出しに失敗しました"
                    }
                }
            } catch {
                self.state = "failed"; self.message = error.localizedDescription
            }
        }
    }
}

extension PurinNativePlugin {
    @objc func endFile(_ call: CAPPluginCall) {
        if let id = call.getString("id") { closeWriting(id) }
        call.resolve()
    }
    @objc func exportStart(_ call: CAPPluginCall) {
        guard let obj = call.options as? [String: Any] else { call.reject("データがありません"); return }
        purinExporter.start(obj, mediaURL: { self.mediaURL($0) }, tmpURL: { self.tmpFileURL($0) })
        call.resolve()
    }
    @objc func exportStatus(_ call: CAPPluginCall) {
        call.resolve(["state": purinExporter.state, "progress": purinExporter.progress, "message": purinExporter.message])
    }
    @objc func exportCancel(_ call: CAPPluginCall) {
        purinExporter.cancel(); call.resolve()
    }
    @objc func clearTemp(_ call: CAPPluginCall) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purin", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension == "png" || u.pathExtension == "wav" { try? FileManager.default.removeItem(at: u) }
        }
        call.resolve()
    }
}


func purinTmpURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purin", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent((name as NSString).lastPathComponent)
}
func purinCacheURL(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("purinaudio", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent((name as NSString).lastPathComponent)
}

// MARK: - 音声補正（iPhoneのオーディオユニットで処理）
/// コンプレッサー（AUDynamicsProcessor）、ノイズ除去・BGM除去（AUSoundIsolation＝声の分離）、リミッター
final class PurinAudioFX {
    static func setParam(_ unit: AVAudioUnit, match: [String], value: AUValue) {
        guard let tree = unit.auAudioUnit.parameterTree else { return }
        for p in tree.allParameters {
            let n = (p.identifier + " " + p.displayName).lowercased()
            if match.contains(where: { n.contains($0) }) { p.value = max(p.minValue, min(p.maxValue, value)); return }
        }
    }

    /// 元動画の音声を補正したファイル（m4a）を作る。同じ設定なら作り直さない
    static func process(source: URL, outName: String, comp: Int, nr: Int, vocal: Bool, progress: @escaping (Double) -> Void) throws -> URL {
        let out = purinCacheURL(outName)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw NSError(domain: "purin", code: 20, userInfo: [NSLocalizedDescriptionKey: "音声がありません"]) }
        let sr: Double = 48000
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false) else { throw NSError(domain: "purin", code: 21) }
        // 1) 元の音声を一時ファイル（CAF）へ
        let raw = purinTmpURL(outName + ".raw.caf")
        try? FileManager.default.removeItem(at: raw)
        do {
            let reader = try AVAssetReader(asset: asset)
            let ro = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false])
            reader.add(ro)
            let file = try AVAudioFile(forWriting: raw, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "purin", code: 22) }
            while let sb = ro.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sb)
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { continue }
                buf.frameLength = AVAudioFrameCount(n)
                let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
                if st == noErr { try file.write(from: buf) }
            }
        }
        defer { try? FileManager.default.removeItem(at: raw) }
        progress(0.15)
        // 2) オーディオユニットを通してオフライン処理
        let input = try AVAudioFile(forReading: raw)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = [player]
        if nr > 0 || vocal {
            let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let iso = AVAudioUnitEffect(audioComponentDescription: desc)
            engine.attach(iso)
            // 声以外をどれだけ消すか（BGM除去は100%、ノイズ除去は弱/強）
            let mix: AUValue = vocal ? 100 : (nr >= 2 ? 90 : 65)
            setParam(iso, match: ["wetdry", "wet", "mix"], value: mix)
            chain.append(iso)
        }
        if comp > 0 {
            let hp = AVAudioUnitEQ(numberOfBands: 1)
            hp.bands[0].filterType = .highPass; hp.bands[0].frequency = 80; hp.bands[0].bypass = false
            engine.attach(hp); chain.append(hp)
            let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let dyn = AVAudioUnitEffect(audioComponentDescription: desc)
            engine.attach(dyn)
            let th: [AUValue] = [-18, -26, -34], gain: [AUValue] = [5, 9, 13]
            let i = min(2, comp - 1)
            AudioUnitSetParameter(dyn.audioUnit, 0, kAudioUnitScope_Global, 0, th[i], 0)      // しきい値
            AudioUnitSetParameter(dyn.audioUnit, 1, kAudioUnitScope_Global, 0, 3, 0)          // ヘッドルーム（圧縮の強さ）
            AudioUnitSetParameter(dyn.audioUnit, 4, kAudioUnitScope_Global, 0, 0.004, 0)      // アタック
            AudioUnitSetParameter(dyn.audioUnit, 5, kAudioUnitScope_Global, 0, 0.12, 0)       // リリース
            AudioUnitSetParameter(dyn.audioUnit, 6, kAudioUnitScope_Global, 0, gain[i], 0)    // 持ち上げ
            chain.append(dyn)
            let limDesc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let lim = AVAudioUnitEffect(audioComponentDescription: limDesc)
            engine.attach(lim); chain.append(lim)
        }
        for i in 0..<(chain.count - 1) { engine.connect(chain[i], to: chain[i + 1], format: fmt) }
        engine.connect(chain[chain.count - 1], to: engine.mainMixerNode, format: fmt)
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(input, at: nil)
        player.play()
        let tmpOut = purinCacheURL(outName + ".part.m4a")
        try? FileManager.default.removeItem(at: tmpOut)
        let outFile = try AVAudioFile(forWriting: tmpOut, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { throw NSError(domain: "purin", code: 23) }
        let total = input.length
        var stall = 0
        while engine.manualRenderingSampleTime < total {
            let before = engine.manualRenderingSampleTime
            let left = total - engine.manualRenderingSampleTime
            let n = AVAudioFrameCount(min(Int64(buf.frameCapacity), left))
            let st = try engine.renderOffline(n, to: buf)
            if st == .success { try outFile.write(from: buf) } else if st == .error { throw NSError(domain: "purin", code: 24, userInfo: [NSLocalizedDescriptionKey: "音声の処理に失敗しました"]) }
            progress(0.15 + 0.85 * Double(engine.manualRenderingSampleTime) / Double(max(1, total)))
            if engine.manualRenderingSampleTime == before { stall += 1; if stall > 50 { break } } else { stall = 0 }
        }
        player.stop(); engine.stop()
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmpOut, to: out)
        return out
    }
}

extension PurinNativePlugin {
    /// 音声補正を作る（裏で処理し、進み具合は audioFXStatus で確認）
    @objc func audioFX(_ call: CAPPluginCall) {
        guard let name = call.getString("name"), let out = call.getString("out") else { call.reject("引数がありません"); return }
        let comp = call.getInt("comp") ?? 0, nr = call.getInt("nr") ?? 0, vocal = call.getBool("vocal") ?? false
        let src = mediaURL(name)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let u = try PurinAudioFX.process(source: src, outName: out, comp: comp, nr: nr, vocal: vocal) { p in
                    self.fxProgress[out] = p
                }
                _ = u
                self.fxProgress[out] = 1
                call.resolve(["file": out])
            } catch {
                self.fxProgress[out] = -1
                call.reject("音声補正できませんでした: \(error.localizedDescription)")
            }
        }
    }
    @objc func audioFXStatus(_ call: CAPPluginCall) {
        call.resolve(["progress": fxProgress[call.getString("out") ?? ""] ?? 0])
    }
}
