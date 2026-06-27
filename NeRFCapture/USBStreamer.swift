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
    // Bounds how many ARFrame pixel buffers we hold for off-thread encoding.
    // The JPEG/depth encode is expensive and must NOT run on the ARSession
    // (main) thread — doing so stalled the live preview and capture. We hand it
    // to `queue` instead, but each in-flight encode retains an ARKit capturedImage
    // buffer; ARKit pools those, so holding too many starves it and stalls frame
    // delivery. A small bound (drop when saturated) keeps capture smooth.
    private let encodeSlots = DispatchSemaphore(value: 2)
    var jpegQuality: CGFloat = 0.7

    private var imuStarted = false      // guard against double CoreMotion subscribe
    private var listenerShouldRun = false  // true between start()/stop(); gates auto-restart

    /// (Re)arm the loopback listener. Safe to call repeatedly — on every USB-mode
    /// select AND every time the app returns to the foreground. Launch order no
    /// longer matters: start the Mac recorder first, then open the app, and the
    /// fresh listener lets iproxy connect — no force-quit needed. A listener that
    /// the OS tears down (backgrounding, resource reclaim) self-heals via the
    /// stateUpdateHandler below instead of wedging until a swipe-kill.
    func start() {
        listenerShouldRun = true
        queue.async { [weak self] in self?.armListener() }
        startIMU()
    }

    func stop() {
        listenerShouldRun = false
        motion.stopDeviceMotionUpdates()
        imuStarted = false
        queue.async { [weak self] in
            self?.connection?.cancel(); self?.connection = nil
            self?.listener?.cancel(); self?.listener = nil
            self?.setConnected(false)
        }
        print("[usb] stopped")
    }

    /// Tear down any prior listener/connection and bind a fresh one. Runs on
    /// `queue` so it never races adopt()/enqueue(), which also touch `listener`
    /// and `connection`.
    private func armListener() {
        guard listenerShouldRun else { return }
        connection?.cancel(); connection = nil
        listener?.cancel()
        setConnected(false)

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // usbmux connects to device loopback
        params.allowLocalEndpointReuse = true      // don't get stuck on a lingering bind
        guard let l = try? NWListener(
            using: params, on: NWEndpoint.Port(rawValue: USBStreamer.port)!) else {
            print("[usb] failed to create listener on \(USBStreamer.port) — retrying in 1s")
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.armListener() }
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.adopt(conn) }
        l.stateUpdateHandler = { [weak self] state in
            print("[usb] listener: \(state)")
            guard let self else { return }
            switch state {
            case .failed:
                // A genuine listener failure (e.g. the OS reclaimed it) — recreate
                // so the Mac can reconnect without a force-quit. We must NOT also
                // re-arm on .cancelled: .cancelled is ALWAYS our own teardown
                // (stop() or a restart), so re-arming on it would make every
                // restart's cancel schedule another restart, tearing the listener
                // down ~once a second and never letting a connection hold.
                if self.listenerShouldRun {
                    self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.armListener()
                    }
                }
            default:
                break
            }
        }
        l.start(queue: queue)
        print("[usb] listening on loopback:\(USBStreamer.port)")
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

    /// Snapshot the (cheap) per-frame metadata + retain the pixel buffers on the
    /// ARSession thread, then do the EXPENSIVE JPEG/depth encode async on the
    /// streamer queue so the AR/main thread returns immediately (a synchronous
    /// encode here stalled the live preview and dropped capture to a few fps).
    /// `encodeSlots` bounds how many ARKit buffers we hold; when encoders are
    /// saturated we drop the frame rather than block the session or starve
    /// ARKit's capturedImage pool.
    func sendFrame(_ frame: ARFrame) {
        guard clientConnected else { return }
        // Non-blocking acquire — saturated ⇒ drop this frame (don't stall ARKit).
        guard encodeSlots.wait(timeout: .now()) == .success else { return }

        let pixelBuffer = frame.capturedImage       // CVPixelBuffer — retained by the closure
        let depthMap = frame.sceneDepth?.depthMap
        let idx = UInt32(frameIndex)
        frameIndex += 1
        let timestamp = frame.timestamp
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let t = frame.camera.transform

        queue.async { [weak self] in
            defer { self?.encodeSlots.signal() }
            guard let self, let jpeg = self.jpegData(pixelBuffer) else { return }

            var depthData = Data()
            var depthW: UInt32 = 0, depthH: UInt32 = 0
            var hasDepth: UInt8 = 0
            if let depthMap {
                let (px, dw, dh) = extractDepthMillimeters(depthMap)
                depthData = px.withUnsafeBytes { Data($0) }
                depthW = UInt32(dw); depthH = UInt32(dh); hasDepth = 1
            }

            var p = Data()
            p.appendLE(idx)
            p.appendLE(timestamp)
            p.appendLE(k[0, 0]); p.appendLE(k[1, 1]); p.appendLE(k[2, 0]); p.appendLE(k[2, 1])
            p.appendLE(UInt32(res.width))
            p.appendLE(UInt32(res.height))
            for col in [t.columns.0, t.columns.1, t.columns.2, t.columns.3] {
                p.appendLE(col.x); p.appendLE(col.y); p.appendLE(col.z); p.appendLE(col.w)
            }
            p.append(hasDepth)
            p.appendLE(depthW); p.appendLE(depthH); p.appendLE(Float(0.001))
            p.appendLE(UInt32(jpeg.count)); p.append(jpeg)
            p.appendLE(UInt32(depthData.count)); p.append(depthData)

            self.sendOnQueue(type: 0, payload: p, droppable: true)
            DispatchQueue.main.async { self.framesSent = Int(idx) + 1 }
        }
    }

    private func jpegData(_ pb: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: jpegQuality)
    }

    // MARK: - IMU

    private func startIMU() {
        guard motion.isDeviceMotionAvailable, !imuStarted else { return }
        imuStarted = true
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

    /// Dispatch onto `queue` then send. For callers NOT already on `queue` (IMU).
    private func enqueue(type: UInt8, payload: Data, droppable: Bool) {
        queue.async { [weak self] in
            self?.sendOnQueue(type: type, payload: payload, droppable: droppable)
        }
    }

    /// Frame + send the payload. MUST be called on `queue` (sendFrame's encode
    /// block already runs there, so it calls this directly — no extra hop).
    private func sendOnQueue(type: UInt8, payload: Data, droppable: Bool) {
        guard let conn = connection else { return }
        if droppable && pendingSends >= maxPendingSends { return }
        var msg = Data()
        msg.append(type)
        msg.appendLE(UInt32(payload.count))
        msg.append(payload)
        pendingSends += 1
        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.pendingSends -= 1 }
        })
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
