//
//  DatasetWriter.swift
//  JediCapture
//
//  Continuous egocentric recorder. Between Start and End it persists, per frame:
//    - RGB    → single HEVC video (rgb.mov)
//    - depth  → lossless 16-bit mm PNG (depth/<i>.png)
//    - pose+intrinsics+timestamp → frames.json
//  and, for the whole session, 100 Hz IMU → imu.csv. All on one device clock.
//

import Foundation
import ARKit
import Zip

class DatasetWriter {

    enum SessionState {
        case SessionNotStarted
        case SessionStarted
    }

    var manifest = Manifest()
    var projectName = ""
    var projectDir = getDocumentsDirectory()
    var useDepthIfAvailable = true
    let motionManager = MotionManager()
    private var videoWriter: VideoWriter?

    @Published var currentFrameCounter = 0
    @Published var writerState = SessionState.SessionNotStarted

    func projectExists(_ projectDir: URL) -> Bool {
        var isDir: ObjCBool = true
        return FileManager.default.fileExists(atPath: projectDir.absoluteString, isDirectory: &isDir)
    }

    func initializeProject() throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyMMddHHmmss"
        projectName = dateFormatter.string(from: Date())
        projectDir = getDocumentsDirectory().appendingPathComponent(projectName)
        if projectExists(projectDir) {
            throw AppError.projectAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("depth"),
            withIntermediateDirectories: true)

        manifest = Manifest()
        videoWriter = nil               // created lazily on first frame (needs dims)
        currentFrameCounter = 0
        // IMU records continuously for the whole session; imu.csv device-clock
        // timestamps align with each frame's `timestamp`.
        motionManager.start(writingTo: projectDir.appendingPathComponent("imu.csv"))
        writerState = .SessionStarted
    }

    func clean() {
        motionManager.stop()
        videoWriter = nil
        guard case .SessionStarted = writerState else { return }
        writerState = .SessionNotStarted
        DispatchQueue.global().async {
            try? FileManager.default.removeItem(at: self.projectDir)
        }
    }

    func finalizeProject(zip: Bool = true) {
        motionManager.stop()
        writerState = .SessionNotStarted
        let dir = projectDir
        let name = projectName
        let manifestSnapshot = manifest

        let writeManifestAndZip = {
            self.writeManifest(manifestSnapshot, to: dir.appendingPathComponent("frames.json"))
            DispatchQueue.global().async {
                do {
                    if zip { _ = try Zip.quickZipFiles([dir], fileName: name) }
                    try FileManager.default.removeItem(at: dir)
                } catch {
                    print("Could not finalize/zip: \(error)")
                }
            }
        }

        // Zip only AFTER the video stream is flushed and closed.
        if let vw = videoWriter {
            vw.finish {
                print("[video] finished: \(vw.appended) appended, \(vw.dropped) dropped")
                writeManifestAndZip()
            }
            videoWriter = nil
        } else {
            writeManifestAndZip()
        }
    }

    func writeManifest(_ manifest: Manifest, to path: URL) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted]
        if let encoded = try? encoder.encode(manifest) {
            do { try encoded.write(to: path) } catch { print(error) }
        }
    }

    func writeFrameToDisk(frame: ARFrame, useDepthIfAvailable: Bool = true) {
        let idx = currentFrameCounter
        let w = Int(frame.camera.imageResolution.width)
        let h = Int(frame.camera.imageResolution.height)

        // First frame fixes the RGB geometry + opens the video stream.
        if manifest.w == 0 {
            manifest.w = w
            manifest.h = h
            manifest.flX = frame.camera.intrinsics[0, 0]
            manifest.flY = frame.camera.intrinsics[1, 1]
            manifest.cx = frame.camera.intrinsics[2, 0]
            manifest.cy = frame.camera.intrinsics[2, 1]
            videoWriter = VideoWriter(
                url: projectDir.appendingPathComponent(manifest.video), width: w, height: h)
        }

        videoWriter?.append(frame.capturedImage, at: frame.timestamp)

        var depthPath: String? = nil
        if useDepthIfAvailable, let sd = frame.sceneDepth {
            // Copy depth out synchronously (ARFrame owns the buffer briefly),
            // then PNG-encode off the capture thread.
            let (px, dw, dh) = extractDepthMillimeters(sd.depthMap)
            if manifest.depthW == 0 { manifest.depthW = dw; manifest.depthH = dh }
            let rel = "depth/\(idx).png"
            let url = projectDir.appendingPathComponent(rel)
            DispatchQueue.global(qos: .utility).async {
                writeDepth16PNG(px, w: dw, h: dh, to: url)
            }
            depthPath = rel
        }

        manifest.frames.append(
            Manifest.Frame(
                frameIndex: idx,
                timestamp: frame.timestamp,
                transformMatrix: arrayFromTransform(frame.camera.transform),
                flX: frame.camera.intrinsics[0, 0],
                flY: frame.camera.intrinsics[1, 1],
                cx: frame.camera.intrinsics[2, 0],
                cy: frame.camera.intrinsics[2, 1],
                w: w, h: h,
                depthPath: depthPath))
        currentFrameCounter += 1
    }
}
