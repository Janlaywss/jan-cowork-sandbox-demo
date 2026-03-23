/// NAPIHelpers.swift — Thin Swift wrappers around the raw C Node-API calls.
import Foundation

// MARK: - Raw C imports (node_api.h symbols are visible via CNapi modulemap)

// We use @_silgen_name to reference the C functions directly because Swift
// Package Manager doesn't support mixed C/Swift targets cleanly.  In production
// you'd use a proper clang module; for this demo the build script passes the
// node include path so the linker resolves these at load time.

public typealias napi_env = OpaquePointer
public typealias napi_value = OpaquePointer
public typealias napi_callback_info = OpaquePointer

// Status codes
let napi_ok: Int32 = 0

// Value types
let napi_undefined_type: Int32 = 0
let napi_null_type: Int32 = 1
let napi_boolean_type: Int32 = 2
let napi_number_type: Int32 = 3
let napi_string_type: Int32 = 4
let napi_object_type: Int32 = 6

// ── Core N-API C functions we call from Swift ──────────────────────────

@_silgen_name("napi_create_string_utf8")
func napi_create_string_utf8(
    _ env: napi_env, _ str: UnsafePointer<CChar>?, _ length: Int,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_create_int32")
func napi_create_int32(
    _ env: napi_env, _ value: Int32,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_create_double")
func napi_create_double(
    _ env: napi_env, _ value: Double,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_get_boolean")
func napi_get_boolean(
    _ env: napi_env, _ value: Bool,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_create_object")
func napi_create_object(
    _ env: napi_env,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_set_named_property")
func napi_set_named_property(
    _ env: napi_env, _ object: napi_value,
    _ name: UnsafePointer<CChar>?, _ value: napi_value
) -> Int32

@_silgen_name("napi_create_function")
func napi_create_function(
    _ env: napi_env, _ utf8name: UnsafePointer<CChar>?, _ length: Int,
    _ cb: @convention(c) (napi_env, napi_callback_info) -> napi_value?,
    _ data: UnsafeMutableRawPointer?,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_get_cb_info")
func napi_get_cb_info(
    _ env: napi_env, _ cbinfo: napi_callback_info,
    _ argc: UnsafeMutablePointer<Int>?,
    _ argv: UnsafeMutablePointer<napi_value?>?,
    _ thisArg: UnsafeMutablePointer<napi_value?>?,
    _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32

@_silgen_name("napi_get_value_string_utf8")
func napi_get_value_string_utf8(
    _ env: napi_env, _ value: napi_value,
    _ buf: UnsafeMutablePointer<CChar>?, _ bufsize: Int,
    _ result: UnsafeMutablePointer<Int>?
) -> Int32

@_silgen_name("napi_get_value_int32")
func napi_get_value_int32(
    _ env: napi_env, _ value: napi_value,
    _ result: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("napi_get_value_bool")
func napi_get_value_bool(
    _ env: napi_env, _ value: napi_value,
    _ result: UnsafeMutablePointer<Bool>
) -> Int32

@_silgen_name("napi_get_undefined")
func napi_get_undefined(
    _ env: napi_env,
    _ result: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_throw_error")
func napi_throw_error(
    _ env: napi_env, _ code: UnsafePointer<CChar>?,
    _ msg: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("napi_create_promise")
func napi_create_promise(
    _ env: napi_env,
    _ deferred: UnsafeMutablePointer<OpaquePointer?>,
    _ promise: UnsafeMutablePointer<napi_value?>
) -> Int32

@_silgen_name("napi_resolve_deferred")
func napi_resolve_deferred(
    _ env: napi_env, _ deferred: OpaquePointer, _ resolution: napi_value
) -> Int32

@_silgen_name("napi_reject_deferred")
func napi_reject_deferred(
    _ env: napi_env, _ deferred: OpaquePointer, _ rejection: napi_value
) -> Int32

@_silgen_name("napi_create_threadsafe_function")
func napi_create_threadsafe_function(
    _ env: napi_env,
    _ func_: napi_value?,
    _ asyncResource: napi_value?,
    _ asyncResourceName: napi_value,
    _ maxQueueSize: Int,
    _ initialThreadCount: Int,
    _ threadFinalizeData: UnsafeMutableRawPointer?,
    _ threadFinalizeCb: (@convention(c) (napi_env, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?,
    _ callJsCb: (@convention(c) (napi_env?, napi_value?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?,
    _ result: UnsafeMutablePointer<OpaquePointer?>
) -> Int32

@_silgen_name("napi_call_threadsafe_function")
func napi_call_threadsafe_function(
    _ func_: OpaquePointer,
    _ data: UnsafeMutableRawPointer?,
    _ isBlocking: Int32
) -> Int32

@_silgen_name("napi_release_threadsafe_function")
func napi_release_threadsafe_function(
    _ func_: OpaquePointer,
    _ mode: Int32
) -> Int32

// ── Swift Helpers ──────────────────────────────────────────────────────

func napiString(_ env: napi_env, _ str: String) -> napi_value? {
    var result: napi_value?
    _ = str.withCString { cstr in
        napi_create_string_utf8(env, cstr, str.utf8.count, &result)
    }
    return result
}

func napiBool(_ env: napi_env, _ val: Bool) -> napi_value? {
    var result: napi_value?
    _ = napi_get_boolean(env, val, &result)
    return result
}

func napiUndefined(_ env: napi_env) -> napi_value? {
    var result: napi_value?
    _ = napi_get_undefined(env, &result)
    return result
}

func napiThrow(_ env: napi_env, _ msg: String) {
    msg.withCString { cstr in
        _ = napi_throw_error(env, nil, cstr)
    }
}

func napiGetString(_ env: napi_env, _ val: napi_value) -> String? {
    var len = 0
    guard napi_get_value_string_utf8(env, val, nil, 0, &len) == napi_ok else { return nil }
    var buf = [CChar](repeating: 0, count: len + 1)
    guard napi_get_value_string_utf8(env, val, &buf, len + 1, nil) == napi_ok else { return nil }
    return String(cString: buf)
}

func napiSetProperty(_ env: napi_env, _ obj: napi_value, _ key: String, _ val: napi_value) {
    key.withCString { cstr in
        _ = napi_set_named_property(env, obj, cstr, val)
    }
}

func napiCreateFunction(
    _ env: napi_env,
    _ name: String,
    _ cb: @escaping @convention(c) (napi_env, napi_callback_info) -> napi_value?
) -> napi_value? {
    var result: napi_value?
    name.withCString { cstr in
        _ = napi_create_function(env, cstr, name.utf8.count, cb, nil, &result)
    }
    return result
}
