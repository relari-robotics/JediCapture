//
//  ARViewModel.swift
//  NeRFCapture
//
//  Created by Jad Abou-Chakra on 13/7/2022.
//

import Foundation
import Zip
import Combine
import ARKit
import RealityKit

enum AppError : Error {
    case projectAlreadyExists
    case manifestInitializationFailed
}

class ARViewModel : NSObject, ARSessionDelegate, ObservableObject {
    @Published var appState = AppState()
    var session: ARSession? = nil
    var arView: ARView? = nil
//    let frameSubject = PassthroughSubject<ARFrame, Never>()
    var cancellables = Set<AnyCancellable>()
    let datasetWriter: DatasetWriter
    let ddsWriter: DDSWriter
    let usbStreamer = USBStreamer()

    // Continuous-capture throttle. ARKit delivers frames at up to 60 Hz; we
    // subsample to a steady target so disk/encoding keeps up. Driven off the
    // device-clock `frame.timestamp`, so capture-card-style drops just widen the
    // next gap instead of compounding (same principle as the GoPro bridge).
    var captureRateHz: Double = 30.0
    private var lastCaptureTime: TimeInterval = 0

    init(datasetWriter: DatasetWriter, ddsWriter: DDSWriter) {
        self.datasetWriter = datasetWriter
        self.ddsWriter = ddsWriter
        super.init()
        self.setupObservers()
        self.ddsWriter.setupDDS()
    }
    
    func setupObservers() {
        datasetWriter.$writerState.sink {x in self.appState.writerState = x} .store(in: &cancellables)
        datasetWriter.$currentFrameCounter.sink { x in self.appState.numFrames = x }.store(in: &cancellables)
        ddsWriter.$peers.sink {x in self.appState.ddsPeers = UInt32(x)}.store(in: &cancellables)
        usbStreamer.$clientConnected.receive(on: RunLoop.main)
            .sink { [weak self] x in self?.appState.usbClientConnected = x }.store(in: &cancellables)
        usbStreamer.$framesSent.receive(on: RunLoop.main)
            .sink { [weak self] x in self?.appState.usbFrames = x }.store(in: &cancellables)

        // The USB listener runs only while USB mode is selected; leaving the mode
        // tears it down so the loopback port is free and IMU updates stop.
        $appState
            .map(\.appMode)
            .prepend(appState.appMode)
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self else { return }
                if mode == .USB { self.usbStreamer.start() } else { self.usbStreamer.stop() }
                print("Changed to \(mode)")
            }
            .store(in: &cancellables)
    }
    
    
    func createARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            // Activate sceneDepth
            configuration.frameSemantics = .sceneDepth
        }
        return configuration
    }
    
    func resetWorldOrigin() {
        session?.pause()
        let config = createARConfiguration()
        session?.run(config, options: [.resetTracking])
    }
    
    
    func session(
        _ session: ARSession,
        didUpdate frame: ARFrame
    ) {
        // One continuous take, subsampled to captureRateHz. Local records to the
        // device; USB streams to the Mac; Wi-Fi (DDS) is driven by the Send button.
        let due = frame.timestamp - lastCaptureTime >= 1.0 / captureRateHz
        switch appState.appMode {
        case .Local:
            if datasetWriter.writerState == .SessionStarted, due {
                lastCaptureTime = frame.timestamp
                datasetWriter.writeFrameToDisk(frame: frame)
            }
        case .USB:
            if usbStreamer.clientConnected, due {
                lastCaptureTime = frame.timestamp
                usbStreamer.sendFrame(frame)
            }
        case .WiFi:
            break
        }
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        self.appState.trackingState = trackingStateToString(camera.trackingState)
    }
}
