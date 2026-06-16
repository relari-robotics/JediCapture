//
//  USBStreamer.swift
//  JediCapture
//
//  Streams the live capture to a connected Mac over USB — no Wi-Fi (that's
//  reserved for the MindRove AP). Transport is a plain TCP listener on the
//  device LOOPBACK interface; the Mac reaches it through usbmux:
//      iproxy <macPort> 10080         # libimobiledevice
//      connect to 127.0.0.1:<macPort> on the Mac
//  Loopback-only binding also sidesteps the iOS local-network permission prompt.
//
//  Wire format (little-endian), one length-prefixed message per send:
//      u8  type            0 = frame, 1 = imu
//      u32 payloadLength
//      payload[payloadLength]
//
//  frame payload:
//      u32 frameIndex
//      f64 deviceTimestamp                 shares ARFrame/CoreMotion clock
//      f32 fx, fy, cx, cy
//      u32 width, height
//      f32 transform[16]                   ARKit camera->world, column-major
//      u8  hasDepth
//      u32 depthWidth, depthHeight
//      f32 depthScale                      depth16 * depthScale = meters (0.001)
//      u32 jpegLength;  jpeg bytes
//      u32 depthLength; depth bytes         uint16 LE millimeters
//
//  imu payload:
//      f64 deviceTimestamp
//      f32 qx,qy,qz,qw, rotX,rotY,rotZ, uaX,uaY,uaZ, gX,gY,gZ
//

import Foundation
import Network
import ARKit
import CoreMotion
import CoreImage
import UIKit

final class USBStreamer {
    static let port: UInt16 = 10080

    private let queue = DispatchQueue(label: "ai.relari.jedicapture.usb")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let ciContext = CIContext()
    private let motion = CMMotionManager()

    @Published var clientConnected = false
    @Published var framesSent = 0

    private var frameIndex = 0          // session-thread only
    private var pendingSends = 0        // streamer-queue only
    private let maxPendingSends = 4     // drop frames if the link backs up
    var jpegQuality: CGFloat = 0.7

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // usbmux connects to device loopback
        guard let l = try? NWListener(
            using: params, on: NWEndpoint.Port(rawValue: USBStreamer.port)!) else {
            print("[usb] failed to create listener on \(USBStreamer.port)")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.adopt(conn) }
        l.stateUpdateHandler = { state in print("[usb] listener: \(state)") }
        l.start(queue: queue)
        startIMU()
        print("[usb] listening on loopback:\(USBStreamer.port)")
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        setConnected(false)
        print("[usb] stopped")
    }

    private func adopt(_ conn: NWConnection) {
        connection?.cancel()            // single client
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setConnected(true); print("[usb] client connected")
            case .failed(let e):
                print("[usb] connection failed: \(e)"); self?.setConnected(false)
            case .cancelled:
                self?.setConnected(false)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func setConnected(_ v: Bool) {
        DispatchQueue.main.async { self.clientConnected = v }
    }

    // MARK: - Frame

    /// Encode + enqueue one frame. Call synchronously from the ARSession thread
    /// (the ARFrame owns its pixel buffers only briefly); the socket send itself
    /// runs async on the streamer queue.
    func sendFrame(_ frame: ARFrame) {
        guard clientConnected, let jpeg = jpegData(frame.capturedImage) else { return }

        var depthData = Data()
        var depthW: UInt32 = 0, depthH: UInt32 = 0
        var hasDepth: UInt8 = 0
        if let sd = frame.sceneDepth {
            let (px, dw, dh) = extractDepthMillimeters(sd.depthMap)
            depthData = px.withUnsafeBytes { Data($0) }
            depthW = UInt32(dw); depthH = UInt32(dh); hasDepth = 1
        }

        let idx = UInt32(frameIndex)
        frameIndex += 1

        var p = Data()
        p.appendLE(idx)
        p.appendLE(frame.timestamp)
        let k = frame.camera.intrinsics
        p.appendLE(k[0, 0]); p.appendLE(k[1, 1]); p.appendLE(k[2, 0]); p.appendLE(k[2, 1])
        p.appendLE(UInt32(frame.camera.imageResolution.width))
        p.appendLE(UInt32(frame.camera.imageResolution.height))
        let t = frame.camera.transform
        for col in [t.columns.0, t.columns.1, t.columns.2, t.columns.3] {
            p.appendLE(col.x); p.appendLE(col.y); p.appendLE(col.z); p.appendLE(col.w)
        }
        p.append(hasDepth)
        p.appendLE(depthW); p.appendLE(depthH); p.appendLE(Float(0.001))
        p.appendLE(UInt32(jpeg.count)); p.append(jpeg)
        p.appendLE(UInt32(depthData.count)); p.append(depthData)

        enqueue(type: 0, payload: p, droppable: true)
        DispatchQueue.main.async { self.framesSent = Int(idx) + 1 }
    }

    private func jpegData(_ pb: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: jpegQuality)
    }

    // MARK: - IMU

    private func startIMU() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue()) {
            [weak self] dm, _ in
            guard let self, let dm, self.clientConnected else { return }
            var p = Data()
            p.appendLE(dm.timestamp)
            let a = dm.attitude.quaternion, r = dm.rotationRate
            let u = dm.userAcceleration, g = dm.gravity
            for v in [a.x, a.y, a.z, a.w, r.x, r.y, r.z, u.x, u.y, u.z, g.x, g.y, g.z] {
                p.appendLE(Float(v))
            }
            self.enqueue(type: 1, payload: p, droppable: false)
        }
    }

    // MARK: - Send

    private func enqueue(type: UInt8, payload: Data, droppable: Bool) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            if droppable && self.pendingSends >= self.maxPendingSends { return }
            var msg = Data()
            msg.append(type)
            msg.appendLE(UInt32(payload.count))
            msg.append(payload)
            self.pendingSends += 1
            conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.pendingSends -= 1 }
            })
        }
    }
}

// Little-endian append helpers for the wire format.
private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt64) {
        var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: Float)  { appendLE(v.bitPattern) }
    mutating func appendLE(_ v: Double) { appendLE(v.bitPattern) }
}
