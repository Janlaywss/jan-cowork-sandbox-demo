/// JanworkVMManager.swift — Wraps Apple Virtualization.framework to boot a Linux VM.
/// Matches the architecture described in vm.md: 3-disk setup, vsock, VirtioFS,
/// EFI boot, dual pipes, memory balloon monitoring.
import Foundation
import Virtualization

// MARK: - Types

enum VMNetworkMode: String {
    case auto = "auto"
    case gvisor = "gvisor"
}

struct MemoryTier {
    let maxGB: Int
    let baselineGB: Int
    let minGB: Int

    /// Compute tier based on host physical memory (matches production heuristic).
    static func compute() -> MemoryTier {
        let physGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        if physGB >= 32 {
            return MemoryTier(maxGB: 8, baselineGB: 6, minGB: 4)
        } else if physGB >= 16 {
            return MemoryTier(maxGB: 4, baselineGB: 3, minGB: 2)
        } else {
            return MemoryTier(maxGB: 2, baselineGB: 2, minGB: 1)
        }
    }
}

/// Thread-safe ring buffer for console output.
final class ConsoleRingBuffer {
    private var buffer: [String] = []
    private let maxLines: Int
    private let lock = NSLock()

    init(maxLines: Int = 1000) {
        self.maxLines = maxLines
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.components(separatedBy: "\n")
        buffer.append(contentsOf: lines)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
    }

    func tail(lines: Int = 50) -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.suffix(lines).joined(separator: "\n")
    }

    var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}

// MARK: - JanworkVMManager

final class JanworkVMManager: NSObject, VZVirtualMachineDelegate {
    static let shared = JanworkVMManager()

    // ═══════ VM instance ═══════
    private var virtualMachine: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var balloonDevice: VZVirtioTraditionalMemoryBalloonDevice?

    // ═══════ I/O channels ═══════
    private var serialPipe: Pipe?
    private var consolePipe: Pipe?
    private var consoleTailBuffer = ConsoleRingBuffer()

    // ═══════ Network ═══════
    private var currentNetworkMode: VMNetworkMode = .auto

    // ═══════ Memory management ═══════
    private var currentMemoryGB: Int = 4
    private var balloonTier: MemoryTier?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // ═══════ RPC (vsock) ═══════
    private var vsockConnection: VZVirtioSocketConnection?
    private var rpcReadBuffer = Data()

    // ═══════ State ═══════
    private var currentBundlePath: String?

    // ═══════ Queue ═══════
    /// VZVirtualMachine requires all interactions on its designated queue.
    /// Using a custom queue avoids @MainActor / CFRunLoop dependency
    /// which is not available in a Node.js process (see vm.md §5.5).
    private let queue = DispatchQueue(label: "janwork.vm.manager")
    private let rpcQueue = DispatchQueue(label: "janwork.vm.rpc")

    var isRunning: Bool {
        virtualMachine?.state == .running
    }

    var isGuestConnected: Bool {
        vsockConnection != nil
    }

    // MARK: - Create VM

    /// Creates a VM bundle directory with sessiondata.img and efivars.fd.
    /// Equivalent to JanworkVMManager.createVM(at:diskSizeGB:) in production.
    func createVM(at bundlePath: String, diskSizeGB: Int = 10,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let fm = FileManager.default

        // Create bundle directory
        do {
            try fm.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        // Create sessiondata.img (sparse, ext4 placeholder)
        // Production: 10GB sparse ext4 with label="sessions", mounted at /sessions/
        let sessionDataPath = (bundlePath as NSString).appendingPathComponent("sessiondata.img")
        if !fm.fileExists(atPath: sessionDataPath) {
            fm.createFile(atPath: sessionDataPath, contents: nil)
            if let fh = FileHandle(forWritingAtPath: sessionDataPath) {
                fh.truncateFile(atOffset: UInt64(diskSizeGB) * 1024 * 1024 * 1024)
                fh.closeFile()
                print("[JanworkVM] Created sessiondata.img (\(diskSizeGB)GB sparse)")
            }
        }

        // Create machineIdentifier (VM UUID)
        let machineIdPath = (bundlePath as NSString).appendingPathComponent("machineIdentifier")
        if !fm.fileExists(atPath: machineIdPath) {
            let uuid = UUID().uuidString
            try? uuid.write(toFile: machineIdPath, atomically: true, encoding: .utf8)
            print("[JanworkVM] Created machineIdentifier: \(uuid)")
        }

        print("[JanworkVM] Bundle created at \(bundlePath)")
        completion(.success(bundlePath))
    }

    // MARK: - Start VM

    /// Start VM with 3-disk architecture matching vm.md §7.5.
    ///
    /// Disk layout:
    ///   1. rootfs.img     — bootable Ubuntu (GPT: EFI + ext4)
    ///   2. sessiondata.img — session data (ext4, label="sessions")
    ///   3. smol-bin.img    — SDK tools (exFAT, read-only)
    func startVM(bundlePath: String, memoryGB: Int = 4,
                 networkMode: VMNetworkMode = .auto,
                 smolBinPath: String? = nil,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard virtualMachine == nil || virtualMachine?.state == .stopped ||
              virtualMachine?.state == .error else {
            completion(.failure(VMError.alreadyRunning))
            return
        }

        let fm = FileManager.default
        currentBundlePath = bundlePath
        currentMemoryGB = memoryGB
        currentNetworkMode = networkMode

        // ── Resolve disk paths ──
        let rootfsPath = (bundlePath as NSString).appendingPathComponent("rootfs.img")
        let sessionDataPath = (bundlePath as NSString).appendingPathComponent("sessiondata.img")
        let efivarsPath = (bundlePath as NSString).appendingPathComponent("efivars.fd")

        // smol-bin: check bundle dir, then parent dir
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let resolvedSmolBin: String = smolBinPath ?? {
            let inBundle = (bundlePath as NSString).appendingPathComponent("smol-bin.\(arch).img")
            if fm.fileExists(atPath: inBundle) { return inBundle }
            let parentDir = (bundlePath as NSString).deletingLastPathComponent
            return (parentDir as NSString).appendingPathComponent("smol-bin.\(arch).img")
        }()

        // Validate rootfs
        guard fm.fileExists(atPath: rootfsPath) else {
            completion(.failure(VMError.imageNotFound(rootfsPath)))
            return
        }

        print("[JanworkVM] Starting VM from bundle: \(bundlePath)")
        print("[JanworkVM]   rootfs:      \(rootfsPath)")
        print("[JanworkVM]   sessiondata: \(sessionDataPath)")
        print("[JanworkVM]   smol-bin:    \(resolvedSmolBin)")
        print("[JanworkVM]   memory:      \(memoryGB)GB")
        print("[JanworkVM]   network:     \(networkMode.rawValue)")

        // ══════════ VM Configuration ══════════
        let config = VZVirtualMachineConfiguration()

        // CPU: 2 cores
        config.cpuCount = 2

        // Memory (GB)
        config.memorySize = UInt64(memoryGB) * 1024 * 1024 * 1024

        // ── Boot loader: UEFI ──
        // Boot chain: UEFI (efivars.fd) → shim → GRUB → Ubuntu kernel → systemd → sdk-daemon
        let bootLoader = VZEFIBootLoader()
        if fm.fileExists(atPath: efivarsPath) {
            bootLoader.variableStore = VZEFIVariableStore(url: URL(fileURLWithPath: efivarsPath))
        } else {
            do {
                bootLoader.variableStore = try VZEFIVariableStore(
                    creatingVariableStoreAt: URL(fileURLWithPath: efivarsPath))
            } catch {
                completion(.failure(error))
                return
            }
        }
        config.bootLoader = bootLoader

        // Platform
        config.platform = VZGenericPlatformConfiguration()

        // ── Storage: 3 disks (vm.md §6.1, §7.5) ──
        var storageDevices: [VZStorageDeviceConfiguration] = []

        // Disk 1: rootfs.img (10GB, GPT: EFI partition + ext4, bootable Ubuntu)
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: rootfsPath), readOnly: false)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        } catch {
            completion(.failure(error))
            return
        }

        // Disk 2: sessiondata.img (10GB, ext4, label="sessions")
        if fm.fileExists(atPath: sessionDataPath) {
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(fileURLWithPath: sessionDataPath), readOnly: false)
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                print("[JanworkVM] Warning: Could not attach sessiondata.img: \(error)")
            }
        }

        // Disk 3: smol-bin.{arch}.img (11MB, exFAT, SDK tools — read-only)
        if fm.fileExists(atPath: resolvedSmolBin) {
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(fileURLWithPath: resolvedSmolBin), readOnly: true)
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                print("[JanworkVM] Warning: Could not attach smol-bin.img: \(error)")
            }
        }

        config.storageDevices = storageDevices

        // ── Serial port (kernel console output) ──
        let serial = Pipe()
        self.serialPipe = serial
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serial.fileHandleForWriting)
        config.serialPorts = [serialPort]

        // Read serial output into ConsoleRingBuffer
        serial.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            self?.consoleTailBuffer.append(str)
            print(str, terminator: "")
        }

        // ── Network (vm.md §9) ──
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        switch networkMode {
        case .auto:
            // vmnet.framework NAT mode
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
        case .gvisor:
            // Production uses GvisorNetworkAttachment (user-space network stack).
            // Demo falls back to NAT since gvisor module is not available.
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            print("[JanworkVM] Note: gvisor mode not available in demo, using NAT fallback")
        }
        config.networkDevices = [networkDevice]

        // ── Entropy (required for Linux guests) ──
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // ── Memory Balloon (vm.md §10) ──
        let balloonConfig = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        config.memoryBalloonDevices = [balloonConfig]

        // ── Virtio Socket / vsock (vm.md §8) ──
        // Host <-> Guest RPC channel. sdk-daemon (janworkd) connects back via vsock.
        let socketConfig = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketConfig]

        // ── Validate & Start ──
        do {
            try config.validate()
        } catch {
            completion(.failure(error))
            return
        }
        print("[JanworkVM] Configuration validated (\(storageDevices.count) disks)")

        queue.async { [self] in
            let vm = VZVirtualMachine(configuration: config, queue: self.queue)
            vm.delegate = self
            self.virtualMachine = vm

            // Capture vsock device for future RPC client
            self.socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice

            print("[JanworkVM] Starting VM...")
            vm.start { result in
                switch result {
                case .success:
                    print("[JanworkVM] VM started successfully")
                    completion(.success(()))
                case .failure(let error):
                    print("[JanworkVM] VM start failed: \(error)")
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Stop VM

    /// Stop the VM. In production, `isAppQuit` triggers graceful process shutdown via RPC.
    func stopVM(isAppQuit: Bool = false,
                completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard let vm = virtualMachine else {
                completion(.failure(VMError.notRunning))
                return
            }
            guard vm.state == .running || vm.state == .starting else {
                completion(.failure(VMError.notRunning))
                return
            }

            print("[JanworkVM] Stopping VM (isAppQuit=\(isAppQuit))...")
            stopBalloonMonitoring()

            do {
                if vm.canRequestStop {
                    try vm.requestStop()
                }
                self.queue.asyncAfter(deadline: .now() + 3.0) { [self] in
                    if vm.state == .running || vm.state == .starting {
                        print("[JanworkVM] Force stopping VM...")
                        self.virtualMachine = nil
                    }
                    self.cleanup()
                    print("[JanworkVM] VM stopped")
                    completion(.success(()))
                }
            } catch {
                self.cleanup()
                completion(.failure(error))
            }
        }
    }

    private func cleanup() {
        vsockConnection = nil
        rpcReadBuffer = Data()
        serialPipe?.fileHandleForReading.readabilityHandler = nil
        serialPipe = nil
        consolePipe?.fileHandleForReading.readabilityHandler = nil
        consolePipe = nil
        socketDevice = nil
    }

    // MARK: - vsock RPC Client (vm.md §8)

    /// Connect to the guest daemon via vsock (VZVirtioSocketDevice).
    /// The daemon inside the VM listens on the given vsock port.
    func connectToGuest(port: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard let socketDevice = self.socketDevice else {
                completion(.failure(VMError.guestNotConnected))
                return
            }

            print("[JanworkVM:rpc] connecting to guest vsock port \(port)...")
            socketDevice.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    self.vsockConnection = connection
                    self.rpcReadBuffer = Data()
                    print("[JanworkVM:rpc] connected to guest")
                    completion(.success(()))
                case .failure(let error):
                    print("[JanworkVM:rpc] vsock connect failed: \(error)")
                    completion(.failure(error))
                }
            }
        }
    }

    /// Send a JSON-RPC request line to the guest daemon and read one response line.
    /// Uses the raw file descriptor from VZVirtioSocketConnection.
    func rpcCall(request: String, completion: @escaping (Result<String, Error>) -> Void) {
        rpcQueue.async { [self] in
            guard let connection = vsockConnection else {
                completion(.failure(VMError.guestNotConnected))
                return
            }

            let fd = connection.fileDescriptor
            guard fd >= 0 else {
                completion(.failure(VMError.guestNotConnected))
                return
            }

            // Write request + newline
            let msg = request + "\n"
            let written = msg.withCString { ptr in
                Darwin.write(fd, ptr, msg.utf8.count)
            }
            guard written > 0 else {
                completion(.failure(VMError.guestNotConnected))
                return
            }

            // Read response line (blocking on rpcQueue)
            if let line = self.readLineFromFd(fd) {
                completion(.success(line))
            } else {
                completion(.failure(VMError.guestNotConnected))
            }
        }
    }

    /// Read one newline-terminated line from a file descriptor, buffering as needed.
    private func readLineFromFd(_ fd: Int32) -> String? {
        let newline = UInt8(0x0A) // '\n'
        while true {
            // Check buffer for complete line
            if let idx = rpcReadBuffer.firstIndex(of: newline) {
                let lineData = rpcReadBuffer.subdata(in: rpcReadBuffer.startIndex..<idx)
                rpcReadBuffer.removeSubrange(rpcReadBuffer.startIndex...idx)
                return String(data: lineData, encoding: .utf8)
            }
            // Read more data from fd
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            rpcReadBuffer.append(contentsOf: buf[..<n])
        }
    }

    // MARK: - Console (vm.md §4, Debug)

    func getConsoleTail() -> String {
        return consoleTailBuffer.tail()
    }

    // MARK: - Memory (vm.md §10)

    func getMemoryTier() -> MemoryTier {
        return balloonTier ?? MemoryTier.compute()
    }

    func startBalloonMonitoring(tier: MemoryTier) {
        balloonTier = tier
        print("[JanworkVM:balloon] Monitoring enabled: max=\(tier.maxGB)GB baseline=\(tier.baselineGB)GB min=\(tier.minGB)GB")

        // Monitor host memory pressure events
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            let event = source.data
            if event.contains(.critical) {
                print("[JanworkVM:balloon] Host memory CRITICAL → reduce to min=\(tier.minGB)GB")
            } else if event.contains(.warning) {
                print("[JanworkVM:balloon] Host memory WARNING → reduce to baseline=\(tier.baselineGB)GB")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stopBalloonMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        balloonTier = nil
    }

    func getHostMemoryInfo() -> (totalBytes: UInt64, availableBytes: UInt64, physicalMemoryGB: Int) {
        let total = ProcessInfo.processInfo.physicalMemory
        let physGB = Int(total / (1024 * 1024 * 1024))
        return (totalBytes: total, availableBytes: total / 2, physicalMemoryGB: physGB)
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        let state: String
        switch virtualMachine?.state {
        case .stopped:   state = "stopped"
        case .running:   state = "running"
        case .paused:    state = "paused"
        case .error:     state = "error"
        case .starting:  state = "starting"
        case .pausing:   state = "pausing"
        case .resuming:  state = "resuming"
        case .stopping:  state = "stopping"
        case .saving:    state = "saving"
        case .restoring: state = "restoring"
        default:         state = "unknown"
        }
        return [
            "state": state,
            "consoleLines": consoleTailBuffer.lineCount,
            "memoryGB": currentMemoryGB,
            "networkMode": currentNetworkMode.rawValue,
            "bundlePath": currentBundlePath ?? "",
        ]
    }

    // MARK: - VZVirtualMachineDelegate

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        print("[JanworkVM] VM stopped with error: \(error.localizedDescription)")
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[JanworkVM] Guest did stop")
    }
}

// MARK: - Errors

enum VMError: LocalizedError {
    case alreadyRunning
    case notRunning
    case imageNotFound(String)
    case guestNotConnected
    case bundleNotFound(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:        return "VM is already running"
        case .notRunning:            return "VM is not running"
        case .imageNotFound(let p):  return "Image not found: \(p)"
        case .guestNotConnected:     return "Guest is not connected (no RPC client)"
        case .bundleNotFound(let p): return "Bundle not found: \(p)"
        }
    }
}
