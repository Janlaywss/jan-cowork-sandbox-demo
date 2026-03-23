/// NAPIModule.swift — N-API entry point.
/// Registers JS-callable functions grouped under a `vm` namespace object,
/// matching the production @ant/claude-swift addon structure (vm.md §5).
import Foundation

// ── Thread-safe function for resolving/rejecting promises from async context ──

private struct AsyncWork {
    let env: napi_env
    let deferred: OpaquePointer
    let resolve: Bool
    let message: String
}

/// Shared callback for threadsafe functions that resolve/reject a deferred promise.
private let asyncResolveCb: @convention(c) (
    napi_env?, napi_value?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { env, _, _, data in
    guard let env = env, let data = data else { return }
    let work = data.assumingMemoryBound(to: AsyncWork.self).pointee
    if work.resolve {
        if let val = napiString(env, work.message) {
            _ = napi_resolve_deferred(env, work.deferred, val)
        }
    } else {
        if let val = napiString(env, work.message) {
            _ = napi_reject_deferred(env, work.deferred, val)
        }
    }
    data.deallocate()
}

/// Create a threadsafe function for resolving promises from a background queue.
private func createTSFN(_ env: napi_env, name: String) -> OpaquePointer? {
    var tsfn: OpaquePointer?
    var resourceName: napi_value?
    _ = name.withCString { cstr in
        napi_create_string_utf8(env, cstr, name.utf8.count, &resourceName)
    }
    _ = napi_create_threadsafe_function(
        env, nil, nil, resourceName!, 0, 1, nil, nil, nil, asyncResolveCb, &tsfn)
    return tsfn
}

/// Resolve or reject a promise via a threadsafe function, then release it.
private func settlePromise(_ tsfn: OpaquePointer, env: napi_env,
                           deferred: OpaquePointer, resolve: Bool, message: String) {
    let ptr = UnsafeMutablePointer<AsyncWork>.allocate(capacity: 1)
    ptr.initialize(to: AsyncWork(env: env, deferred: deferred,
                                 resolve: resolve, message: message))
    _ = napi_call_threadsafe_function(tsfn, ptr, 0)
    _ = napi_release_threadsafe_function(tsfn, 0)
}

// ── N-API Module Registration ──

@_cdecl("napi_register_module_v1")
public func napi_register_module_v1(
    env: napi_env,
    exports: napi_value
) -> napi_value {
    // Create `vm` namespace object (matches production: native.vm.*)
    var vmObj: napi_value?
    _ = napi_create_object(env, &vmObj)
    guard let vm = vmObj else { return exports }

    // ── Lifecycle ──
    if let fn = napiCreateFunction(env, "createVM", js_createVM) {
        napiSetProperty(env, vm, "createVM", fn)
    }
    if let fn = napiCreateFunction(env, "startVM", js_startVM) {
        napiSetProperty(env, vm, "startVM", fn)
    }
    if let fn = napiCreateFunction(env, "stopVM", js_stopVM) {
        napiSetProperty(env, vm, "stopVM", fn)
    }
    if let fn = napiCreateFunction(env, "isRunning", js_isRunning) {
        napiSetProperty(env, vm, "isRunning", fn)
    }
    if let fn = napiCreateFunction(env, "isGuestConnected", js_isGuestConnected) {
        napiSetProperty(env, vm, "isGuestConnected", fn)
    }

    // ── Debug / Console ──
    if let fn = napiCreateFunction(env, "getConsoleTail", js_getConsoleTail) {
        napiSetProperty(env, vm, "getConsoleTail", fn)
    }
    if let fn = napiCreateFunction(env, "getStatus", js_getStatus) {
        napiSetProperty(env, vm, "getStatus", fn)
    }

    // ── Memory ──
    if let fn = napiCreateFunction(env, "getMemoryTier", js_getMemoryTier) {
        napiSetProperty(env, vm, "getMemoryTier", fn)
    }
    if let fn = napiCreateFunction(env, "getHostMemoryInfo", js_getHostMemoryInfo) {
        napiSetProperty(env, vm, "getHostMemoryInfo", fn)
    }

    // ── RPC (vsock → guest daemon) ──
    if let fn = napiCreateFunction(env, "connectGuest", js_connectGuest) {
        napiSetProperty(env, vm, "connectGuest", fn)
    }
    if let fn = napiCreateFunction(env, "rpcCall", js_rpcCall) {
        napiSetProperty(env, vm, "rpcCall", fn)
    }

    // Set vm namespace on exports
    napiSetProperty(env, exports, "vm", vm)

    print("[JanworkVM] N-API module registered (vm namespace)")
    return exports
}

// ══════════════════════════════════════════════════════════════════════
// MARK: - JS-callable Functions
// ══════════════════════════════════════════════════════════════════════

// ── createVM(bundlePath: string, diskSizeGB?: number) → Promise<string> ──

private func js_createVM(env: napi_env, info: napi_callback_info) -> napi_value? {
    var argc = 2
    var argv: [napi_value?] = [nil, nil]
    _ = napi_get_cb_info(env, info, &argc, &argv, nil, nil)

    guard argc >= 1, let pathVal = argv[0],
          let bundlePath = napiGetString(env, pathVal) else {
        napiThrow(env, "createVM requires bundlePath argument")
        return napiUndefined(env)
    }

    var diskSizeGB: Int32 = 10
    if argc >= 2, let sizeVal = argv[1] {
        var val: Int32 = 0
        if napi_get_value_int32(env, sizeVal, &val) == napi_ok && val > 0 {
            diskSizeGB = val
        }
    }

    // Create promise
    var deferred: OpaquePointer?
    var promise: napi_value?
    guard napi_create_promise(env, &deferred, &promise) == napi_ok,
          let deferred = deferred else {
        napiThrow(env, "Failed to create promise")
        return napiUndefined(env)
    }

    guard let tsfn = createTSFN(env, name: "janworkvm_createvm") else {
        napiThrow(env, "Failed to create threadsafe function")
        return napiUndefined(env)
    }
    let tsfnEnv = env

    JanworkVMManager.shared.createVM(at: bundlePath, diskSizeGB: Int(diskSizeGB)) { result in
        switch result {
        case .success(let path):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: true, message: path)
        case .failure(let error):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: false, message: error.localizedDescription)
        }
    }

    return promise
}

// ── startVM(bundlePath, memoryGB?, networkMode?) → Promise<string> ──

private func js_startVM(env: napi_env, info: napi_callback_info) -> napi_value? {
    var argc = 4
    var argv: [napi_value?] = [nil, nil, nil, nil]
    _ = napi_get_cb_info(env, info, &argc, &argv, nil, nil)

    guard argc >= 1, let pathVal = argv[0],
          let bundlePath = napiGetString(env, pathVal) else {
        napiThrow(env, "startVM requires bundlePath argument")
        return napiUndefined(env)
    }

    var memoryGB: Int32 = 4
    if argc >= 2, let memVal = argv[1] {
        var val: Int32 = 0
        if napi_get_value_int32(env, memVal, &val) == napi_ok && val > 0 {
            memoryGB = val
        }
    }

    var networkMode: VMNetworkMode = .auto
    if argc >= 3, let modeVal = argv[2], let modeStr = napiGetString(env, modeVal) {
        networkMode = VMNetworkMode(rawValue: modeStr) ?? .auto
    }

    // Optional: smolBinPath override (arg 4, demo convenience)
    var smolBinPath: String?
    if argc >= 4, let sbVal = argv[3] {
        smolBinPath = napiGetString(env, sbVal)
    }

    // Create promise
    var deferred: OpaquePointer?
    var promise: napi_value?
    guard napi_create_promise(env, &deferred, &promise) == napi_ok,
          let deferred = deferred else {
        napiThrow(env, "Failed to create promise")
        return napiUndefined(env)
    }

    guard let tsfn = createTSFN(env, name: "janworkvm_startvm") else {
        napiThrow(env, "Failed to create threadsafe function")
        return napiUndefined(env)
    }
    let tsfnEnv = env

    JanworkVMManager.shared.startVM(
        bundlePath: bundlePath,
        memoryGB: Int(memoryGB),
        networkMode: networkMode,
        smolBinPath: smolBinPath
    ) { result in
        switch result {
        case .success:
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: true, message: "VM started")
        case .failure(let error):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: false, message: error.localizedDescription)
        }
    }

    return promise
}

// ── stopVM(isAppQuit?: boolean) → Promise<string> ──

private func js_stopVM(env: napi_env, info: napi_callback_info) -> napi_value? {
    var argc = 1
    var argv: [napi_value?] = [nil]
    _ = napi_get_cb_info(env, info, &argc, &argv, nil, nil)

    var isAppQuit = false
    if argc >= 1, let val = argv[0] {
        var b = false
        if napi_get_value_bool(env, val, &b) == napi_ok {
            isAppQuit = b
        }
    }

    var deferred: OpaquePointer?
    var promise: napi_value?
    guard napi_create_promise(env, &deferred, &promise) == napi_ok,
          let deferred = deferred else {
        napiThrow(env, "Failed to create promise")
        return napiUndefined(env)
    }

    guard let tsfn = createTSFN(env, name: "janworkvm_stopvm") else {
        napiThrow(env, "Failed to create threadsafe function")
        return napiUndefined(env)
    }
    let tsfnEnv = env

    JanworkVMManager.shared.stopVM(isAppQuit: isAppQuit) { result in
        switch result {
        case .success:
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: true, message: "VM stopped")
        case .failure(let error):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: false, message: error.localizedDescription)
        }
    }

    return promise
}

// ── isRunning() → boolean ──

private func js_isRunning(env: napi_env, info: napi_callback_info) -> napi_value? {
    return napiBool(env, JanworkVMManager.shared.isRunning)
}

// ── isGuestConnected() → boolean ──

private func js_isGuestConnected(env: napi_env, info: napi_callback_info) -> napi_value? {
    return napiBool(env, JanworkVMManager.shared.isGuestConnected)
}

// ── getConsoleTail() → string ──

private func js_getConsoleTail(env: napi_env, info: napi_callback_info) -> napi_value? {
    let tail = JanworkVMManager.shared.getConsoleTail()
    return napiString(env, tail)
}

// ── getStatus() → { state, consoleLines, memoryGB, networkMode, bundlePath } ──

private func js_getStatus(env: napi_env, info: napi_callback_info) -> napi_value? {
    let status = JanworkVMManager.shared.getStatus()
    var obj: napi_value?
    _ = napi_create_object(env, &obj)
    guard let obj = obj else { return napiUndefined(env) }

    if let state = status["state"] as? String, let val = napiString(env, state) {
        napiSetProperty(env, obj, "state", val)
    }
    if let lines = status["consoleLines"] as? Int {
        var val: napi_value?
        _ = napi_create_int32(env, Int32(lines), &val)
        if let val = val { napiSetProperty(env, obj, "consoleLines", val) }
    }
    if let gb = status["memoryGB"] as? Int {
        var val: napi_value?
        _ = napi_create_int32(env, Int32(gb), &val)
        if let val = val { napiSetProperty(env, obj, "memoryGB", val) }
    }
    if let mode = status["networkMode"] as? String, let val = napiString(env, mode) {
        napiSetProperty(env, obj, "networkMode", val)
    }
    if let bp = status["bundlePath"] as? String, let val = napiString(env, bp) {
        napiSetProperty(env, obj, "bundlePath", val)
    }

    return obj
}

// ── getMemoryTier() → { maxGB, baselineGB, minGB } ──

private func js_getMemoryTier(env: napi_env, info: napi_callback_info) -> napi_value? {
    let tier = JanworkVMManager.shared.getMemoryTier()
    var obj: napi_value?
    _ = napi_create_object(env, &obj)
    guard let obj = obj else { return napiUndefined(env) }

    var maxVal: napi_value?
    _ = napi_create_int32(env, Int32(tier.maxGB), &maxVal)
    if let v = maxVal { napiSetProperty(env, obj, "maxGB", v) }

    var baseVal: napi_value?
    _ = napi_create_int32(env, Int32(tier.baselineGB), &baseVal)
    if let v = baseVal { napiSetProperty(env, obj, "baselineGB", v) }

    var minVal: napi_value?
    _ = napi_create_int32(env, Int32(tier.minGB), &minVal)
    if let v = minVal { napiSetProperty(env, obj, "minGB", v) }

    return obj
}

// ── getHostMemoryInfo() → { totalBytes, availableBytes, physicalMemoryGB } ──

private func js_getHostMemoryInfo(env: napi_env, info: napi_callback_info) -> napi_value? {
    let info = JanworkVMManager.shared.getHostMemoryInfo()
    var obj: napi_value?
    _ = napi_create_object(env, &obj)
    guard let obj = obj else { return napiUndefined(env) }

    var totalVal: napi_value?
    _ = napi_create_double(env, Double(info.totalBytes), &totalVal)
    if let v = totalVal { napiSetProperty(env, obj, "totalBytes", v) }

    var availVal: napi_value?
    _ = napi_create_double(env, Double(info.availableBytes), &availVal)
    if let v = availVal { napiSetProperty(env, obj, "availableBytes", v) }

    var physVal: napi_value?
    _ = napi_create_int32(env, Int32(info.physicalMemoryGB), &physVal)
    if let v = physVal { napiSetProperty(env, obj, "physicalMemoryGB", v) }

    return obj
}

// ── connectGuest(port: number) → Promise<string> ──

private func js_connectGuest(env: napi_env, info: napi_callback_info) -> napi_value? {
    var argc = 1
    var argv: [napi_value?] = [nil]
    _ = napi_get_cb_info(env, info, &argc, &argv, nil, nil)

    var port: Int32 = 9100
    if argc >= 1, let val = argv[0] {
        var p: Int32 = 0
        if napi_get_value_int32(env, val, &p) == napi_ok && p > 0 {
            port = p
        }
    }

    var deferred: OpaquePointer?
    var promise: napi_value?
    guard napi_create_promise(env, &deferred, &promise) == napi_ok,
          let deferred = deferred else {
        napiThrow(env, "Failed to create promise")
        return napiUndefined(env)
    }

    guard let tsfn = createTSFN(env, name: "janworkvm_connectguest") else {
        napiThrow(env, "Failed to create threadsafe function")
        return napiUndefined(env)
    }
    let tsfnEnv = env

    JanworkVMManager.shared.connectToGuest(port: UInt32(port)) { result in
        switch result {
        case .success:
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: true, message: "connected")
        case .failure(let error):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: false, message: error.localizedDescription)
        }
    }

    return promise
}

// ── rpcCall(jsonLine: string) → Promise<string> ──

private func js_rpcCall(env: napi_env, info: napi_callback_info) -> napi_value? {
    var argc = 1
    var argv: [napi_value?] = [nil]
    _ = napi_get_cb_info(env, info, &argc, &argv, nil, nil)

    guard argc >= 1, let reqVal = argv[0],
          let request = napiGetString(env, reqVal) else {
        napiThrow(env, "rpcCall requires a JSON string argument")
        return napiUndefined(env)
    }

    var deferred: OpaquePointer?
    var promise: napi_value?
    guard napi_create_promise(env, &deferred, &promise) == napi_ok,
          let deferred = deferred else {
        napiThrow(env, "Failed to create promise")
        return napiUndefined(env)
    }

    guard let tsfn = createTSFN(env, name: "janworkvm_rpccall") else {
        napiThrow(env, "Failed to create threadsafe function")
        return napiUndefined(env)
    }
    let tsfnEnv = env

    JanworkVMManager.shared.rpcCall(request: request) { result in
        switch result {
        case .success(let response):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: true, message: response)
        case .failure(let error):
            settlePromise(tsfn, env: tsfnEnv, deferred: deferred,
                          resolve: false, message: error.localizedDescription)
        }
    }

    return promise
}
