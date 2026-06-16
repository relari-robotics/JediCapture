//
//  AppState.swift
//  NeRFCapture
//
//  Created by Jad Abou-Chakra on 13/7/2022.
//

import Foundation
import Metal
import MetalKit

enum AppMode: Int, Codable {
    case Local      // record to device (offload over USB later)
    case WiFi       // live stream over Wi-Fi (CycloneDDS)
    case USB        // live stream over USB (loopback TCP via usbmux)
}

struct AppState {
    var appMode: AppMode = .USB
    var writerState: DatasetWriter.SessionState = .SessionNotStarted

    var trackingState = ""
    var projectName = ""
    var numFrames = 0
    var supportsDepth = false

    var ddsPeers: UInt32 = 0
    var ddsReady = false

    var usbClientConnected = false
    var usbFrames = 0
}

struct AppSettings: Codable {
    var zipDataset = true
    var startingAppMode = AppMode.USB
}



struct MetalState {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    
    var sharedUniformBuffer: MTLBuffer!
    var imagePlaneVertexBuffer: MTLBuffer!
    
    var capturedImagePipelineState: MTLRenderPipelineState!
    var capturedImageTextureY: CVMetalTexture?
    var capturedImageTextureCbCr: CVMetalTexture?
    var capturedImageTextureCache: CVMetalTextureCache!
}
