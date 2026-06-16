//
//  MotionManager.swift
//  JediCapture
//
//  Records device IMU (CoreMotion device-motion) to a CSV alongside the ARKit
//  session. NeRFCapture had no inertial stream; egocentric VLA demos want it,
//  both as a quality signal and so the host can run/refine its own VIO.
//
//  Clock note (load-bearing): CMDeviceMotion.timestamp (a CMLogItem timestamp)
//  is seconds since device boot — the SAME systemUptime / mach timebase as
//  ARFrame.timestamp. We log the raw device timestamp here and in the per-frame
//  metadata so the host can place IMU and camera/pose samples on one device
//  clock, then map that clock onto the LSL timeline with a single offset
//  (mirrors the MindRove/force-glove anchoring in jedi/docs/reference/
//  lsl-how-it-works.md). Do NOT restamp on arrival — that reintroduces jitter.
//

import Foundation
import CoreMotion

final class MotionManager {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var handle: FileHandle?
    private var buffer = Data()
    private let bufferFlushBytes = 64 * 1024

    /// Device-motion update rate. CoreMotion caps this near ~100 Hz on most
    /// iPhones; request it explicitly rather than relying on the default.
    var rateHz: Double = 100.0

    private(set) var sampleCount = 0
    private(set) var isRunning = false

    // rotationRate = calibrated gyro (rad/s); userAcceleration = gravity-removed
    // accel (g); gravity = gravity vector (g) — userAccel + gravity = raw accel.
    // attitude quaternion lets the host sanity-check ARKit's orientation.
    private static let header =
        "t_device,att_qx,att_qy,att_qz,att_qw,rot_x,rot_y,rot_z," +
        "ua_x,ua_y,ua_z,grav_x,grav_y,grav_z\n"

    func start(writingTo url: URL) {
        guard motion.isDeviceMotionAvailable else {
            print("[imu] device motion unavailable — no IMU will be recorded")
            return
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        if handle == nil {
            print("[imu] could not open \(url.path) for writing")
            return
        }
        buffer.removeAll(keepingCapacity: true)
        buffer.append(MotionManager.header.data(using: .utf8)!)
        sampleCount = 0

        queue.maxConcurrentOperationCount = 1   // serial: append() and the stop()
        queue.qualityOfService = .userInitiated // flush never race the file handle
        motion.deviceMotionUpdateInterval = 1.0 / rateHz
        motion.showsDeviceMovementDisplay = true
        // .xArbitraryZVertical: yaw arbitrary, gravity resolved — consistent with
        // ARWorldTrackingConfiguration.worldAlignment = .gravity used by the session.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.append(dm)
        }
        isRunning = true
        print("[imu] started @ \(rateHz) Hz → \(url.lastPathComponent)")
    }

    private func append(_ dm: CMDeviceMotion) {
        let a = dm.attitude.quaternion
        let r = dm.rotationRate
        let u = dm.userAcceleration
        let g = dm.gravity
        let row = "\(dm.timestamp),\(a.x),\(a.y),\(a.z),\(a.w)," +
                  "\(r.x),\(r.y),\(r.z),\(u.x),\(u.y),\(u.z),\(g.x),\(g.y),\(g.z)\n"
        buffer.append(row.data(using: .utf8)!)
        sampleCount += 1
        if buffer.count >= bufferFlushBytes, let h = handle {
            h.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func stop() {
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        isRunning = false
        // Flush + close on the same serial queue the callback uses, so the final
        // write can't race an in-flight append().
        queue.addOperation { [weak self] in
            guard let self else { return }
            if !self.buffer.isEmpty, let h = self.handle {
                h.write(self.buffer)
                self.buffer.removeAll()
            }
            try? self.handle?.close()
            self.handle = nil
        }
        queue.waitUntilAllOperationsAreFinished()
        print("[imu] stopped — \(sampleCount) samples")
    }
}
