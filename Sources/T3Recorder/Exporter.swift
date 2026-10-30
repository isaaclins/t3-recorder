import AVFoundation
import AppKit
import ImageIO
import RecorderCore
import UniformTypeIdentifiers

struct ExportResult {
    var text: String
    var folder: URL
    var uploaded: Bool
}

/// Turns a project into what the agent gets: one video, the screenshots, a page and the clipboard text.
enum Exporter {
    struct Timeline {
        var composition: AVMutableComposition
        var video: AVMutableVideoComposition
        var size: CGSize
    }

    static func timeline(_ p: Project, in dir: URL, burnOverlays: Bool) async throws -> Timeline {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError("Could not start the video export.")
        }
        var size = CGSize.zero
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlayTimes: [(Overlay, Double)] = []
        var hasAudio = false

        for seg in p.segments {
            guard let clip = p.clip(seg.clipID) else { continue }
            let asset = AVURLAsset(url: dir.appendingPathComponent(clip.videoFile))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let natural = try await track.load(.naturalSize)
            let available = try await track.load(.timeRange)
            if size == .zero {
                let scale = min(1, 1920 / natural.width)
                size = CGSize(width: Double(Int(natural.width * scale) & ~1), height: Double(Int(natural.height * scale) & ~1))
            }
            let range = CMTimeRangeGetIntersection(
                CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: 600), end: CMTime(seconds: seg.end, preferredTimescale: 600)), otherRange: available)
            guard range.duration > .zero else { continue }
            try vTrack.insertTimeRange(range, of: track, at: cursor)

            if let name = clip.audioFile {
                let audio = AVURLAsset(url: dir.appendingPathComponent(name))
                if let aSource = try await audio.loadTracks(withMediaType: .audio).first {
                    let wanted = CMTimeRange(start: CMTime(seconds: seg.start - clip.audioOffset, preferredTimescale: 600), duration: range.duration)
                    let usable = CMTimeRangeGetIntersection(wanted, otherRange: try await aSource.load(.timeRange))
                    if usable.duration > .zero {
                        try aTrack.insertTimeRange(usable, of: aSource, at: cursor + (usable.start - wanted.start))
                        hasAudio = true
                    }
                }
            }

            let scale = min(size.width / natural.width, size.height / natural.height)
            let placed = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
                translationX: (size.width - natural.width * scale) / 2, y: (size.height - natural.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            layer.setTransform(placed, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            for o in p.overlays where o.clipID == seg.clipID && o.t >= seg.start && o.t < seg.end {
                overlayTimes.append((o, cursor.seconds + o.t - seg.start))
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw RecorderError("Nothing is left of this recording.") }
        if !hasAudio { comp.removeTrack(aTrack) }

        let video = AVMutableVideoComposition()
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = instructions
        if burnOverlays, !overlayTimes.isEmpty {
            video.animationTool = overlayTool(overlayTimes, size: size)
        }
        return Timeline(composition: comp, video: video, size: size)
    }

    static func overlayTool(_ items: [(Overlay, Double)], size: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer(), videoLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        videoLayer.frame = parent.frame
        parent.isGeometryFlipped = true
        parent.addSublayer(videoLayer)
        for (o, t) in items {
            let layer = OverlayArt.layer(o, in: size)
            layer.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + t
            show.duration = o.duration
            show.isRemovedOnCompletion = true
            layer.add(show, forKey: "show")
            parent.addSublayer(layer)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    static func run(_ p: Project, in dir: URL, config: Config, status: @escaping @Sendable (String) -> Void) async throws -> ExportResult {
        let out = dir.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: out)
        let framesDir = out.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        status("Rendering video…")
        let tl = try await timeline(p, in: dir, burnOverlays: true)
        let movie = out.appendingPathComponent("recording.mp4")
        guard let session = AVAssetExportSession(asset: tl.composition, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw RecorderError("This Mac can't export the video.")
        }
        session.videoComposition = tl.video
        try await session.export(to: movie, as: .mp4)

        status("Picking screenshots…")
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let changes = FramePicker.sceneChanges(samples: try await lumaSamples(asset, duration: duration))
        let chosen = FramePicker.choose(FramePicker.moments(p, sceneChanges: changes, duration: duration))
        let frames = try await writeFrames(chosen, asset: asset, to: framesDir)

        let remoteFolder = "\(config.remoteRoot)/\(p.id)"
        let pageURL = "\(config.webRoot)/\(p.id)/"
        try Page.html(p, frames: frames).write(to: out.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var text = Report.clipboard(p, frames: frames, links: ReportLinks(folder: remoteFolder, pageURL: pageURL))
        try text.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)

        // Screenshots and text first: that is what the agent reads, and it fits through a phone hotspot in seconds.
        status("Uploading…")
        var uploaded = true
        do {
            try await Uploader.send(out, id: p.id, config: config, mode: "replace", exclude: "recording.mp4")
            let background = out
            Task.detached {
                do { try await Uploader.send(background, id: p.id, config: config, mode: "add", only: "recording.mp4") } catch { Log.info("video upload failed: \(error)") }
            }
        } catch {
            Log.info("upload failed: \(error)")
            uploaded = false
            text = Report.clipboard(p, frames: frames, links: ReportLinks(folder: nil, pageURL: nil))
        }
        return ExportResult(text: text, folder: out, uploaded: uploaded)
    }

    /// One small grey picture per second (fewer on long recordings) to notice when the screen changes.
    static func lumaSamples(_ asset: AVAsset, duration: Double) async throws -> [(t: Double, luma: [UInt8])] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let step = max(1, duration / 300)
        var out: [(t: Double, luma: [UInt8])] = []
        var t = 0.0
        while t < duration {
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                out.append((t, luma(image)))
            }
            t += step
        }
        return out
    }

    private static func luma(_ image: CGImage) -> [UInt8] {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .medium
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    private static func writeFrames(_ moments: [Moment], asset: AVAsset, to dir: URL) async throws -> [FrameRef] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        var out: [FrameRef] = []
        for m in moments {
            guard let image = try? await generator.image(at: CMTime(seconds: m.t, preferredTimescale: 600)).image else { continue }
            let name = String(format: "f-%02d-%02d-%d.jpg", Int(m.t) / 60, Int(m.t) % 60, Int(m.t * 10) % 10)
            guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(dest) { out.append(FrameRef(t: m.t, file: "frames/\(name)")) }
        }
        return out
    }
}

/// Shapes as Core Animation layers, the same art for the burned-in video and the editor preview.
enum OverlayArt {
    static let red = CGColor(red: 1, green: 0.17, blue: 0.2, alpha: 1)

    static func layer(_ o: Overlay, in size: CGSize) -> CALayer {
        let rect = CGRect(x: o.rect.x * size.width, y: o.rect.y * size.height, width: o.rect.w * size.width, height: o.rect.h * size.height)
        let line = max(4, size.width / 320)
        if o.shape == .text {
            let text = CATextLayer()
            text.string = o.text ?? ""
            text.fontSize = max(24, size.height / 28)
            text.foregroundColor = CGColor(gray: 1, alpha: 1)
            text.backgroundColor = red
            text.cornerRadius = 6
            text.alignmentMode = .center
            text.contentsScale = 2
            let width = max(rect.width, CGFloat((o.text ?? "").count) * text.fontSize * 0.62 + 24)
            text.frame = CGRect(x: rect.minX, y: rect.minY, width: min(width, size.width - rect.minX), height: text.fontSize * 1.5)
            return text
        }
        let shape = CAShapeLayer()
        shape.frame = CGRect(origin: .zero, size: size)
        shape.fillColor = nil
        shape.strokeColor = red
        shape.lineWidth = line
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.path = path(o, rect: rect, head: line * 5)
        return shape
    }

    static func path(_ o: Overlay, rect: CGRect, head: CGFloat) -> CGPath {
        let p = CGMutablePath()
        switch o.shape {
        case .circle: p.addEllipse(in: rect)
        case .arrow:
            let a = CGPoint(x: o.flipX ? rect.maxX : rect.minX, y: o.flipY ? rect.maxY : rect.minY)
            let b = CGPoint(x: o.flipX ? rect.minX : rect.maxX, y: o.flipY ? rect.minY : rect.maxY)
            addArrow(p, from: a, to: b, head: head)
        default: p.addRect(rect)
        }
        return p
    }

    static func addArrow(_ p: CGMutablePath, from a: CGPoint, to b: CGPoint, head: CGFloat) {
        p.move(to: a)
        p.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [-0.5, 0.5] {
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x - head * cos(angle + side), y: b.y - head * sin(angle + side)))
        }
    }
}

/// The page Isaac gets for a recording: video plus the timeline, click a line to jump there.
enum Page {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ p: Project, frames: [FrameRef]) -> String {
        var rows = ""
        for r in Report.rows(p, frames: frames) {
            let body = r.frame.map { "<img loading=lazy src=\"\(esc($0))\" alt=\"Screenshot\">" } ?? esc(r.text)
            rows += "<button data-t=\"\(r.t)\"><b>\(Report.stamp(r.t))</b><i>\(r.label.lowercased())</i><span>\(body)</span></button>\n"
        }
        return """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>\(p.id)</title>
        <style>
        body{margin:0;font:15px/1.45 -apple-system,system-ui,sans-serif;background:#111;color:#eee}
        main{max-width:1000px;margin:auto;padding:16px}
        video{width:100%;border-radius:8px;background:#000;position:sticky;top:8px}
        button{all:unset;display:grid;grid-template-columns:52px 52px 1fr;gap:8px;width:100%;padding:8px 4px;border-bottom:1px solid #2a2a2a;cursor:pointer;box-sizing:border-box}
        button:hover,button:focus-visible{background:#1d1d1d}
        b{font-variant-numeric:tabular-nums}i{font-style:normal;color:#999}img{max-width:100%;border-radius:6px}
        </style>
        <main><video id=v src="recording.mp4" controls playsinline></video>
        \(rows)</main>
        <script>
        const v=document.getElementById('v');
        document.querySelectorAll('button').forEach(b=>b.onclick=()=>{v.currentTime=+b.dataset.t;v.play()});
        </script>
        """
    }
}

/// Copies files to the Mac mini over ssh with a key that can do nothing except hand over a recording (server/receive-recording).
enum Uploader {
    static func send(_ folder: URL, id: String, config: Config, mode: String, exclude: String? = nil, only: String? = nil) async throws {
        let script = #"""
        set -o pipefail 2>/dev/null
        cd "$1" || exit 1
        if [ -n "$5" ]; then /usr/bin/tar -cf - "$5"; else /usr/bin/tar --exclude "$4" -cf - .; fi | \
        /usr/bin/ssh -i "$2" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$3" "$6"
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "upload", folder.path, Config.keyFile.path, config.sshTarget, exclude ?? "", only ?? "", "\(id) \(mode)"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let status: Int32 = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                p.waitUntilExit()
                c.resume(returning: p.terminationStatus)
            }
        }
        guard status == 0 else {
            let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RecorderError("Upload failed (\(status)): \(why)")
        }
    }
}
