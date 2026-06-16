//
//  Manifest.swift
//  JediCapture
//
//  Serialized to frames.json. RGB lives in a single HEVC video (`video`); each
//  Frame entry maps a video frame index to its 6-DoF camera pose, intrinsics,
//  device-clock timestamp, and (optional) depth PNG. Snake-cased on encode.
//

import Foundation

struct Manifest : Codable {
    struct Frame : Codable {
        let frameIndex: Int          // == index into the HEVC video stream
        let timestamp: TimeInterval  // device clock (shared with imu.csv)
        let transformMatrix: [[Float]]  // 4x4 camera→world (ARKit, gravity-aligned)
        let flX: Float
        let flY: Float
        let cx: Float
        let cy: Float
        let w: Int
        let h: Int
        let depthPath: String?       // e.g. "depth/0.png", nil if unavailable
    }

    var video: String = "rgb.mov"
    var fps: Double = 30
    var depthScale: Float = 0.001    // depth_png_value * depthScale = meters
    var depthW: Int = 0
    var depthH: Int = 0

    // First-frame RGB intrinsics/size (per-frame values also live on each Frame).
    var w: Int = 0
    var h: Int = 0
    var flX: Float = 0
    var flY: Float = 0
    var cx: Float = 0
    var cy: Float = 0

    var frames: [Frame] = [Frame]()
}
