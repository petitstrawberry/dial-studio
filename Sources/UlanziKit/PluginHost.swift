import Foundation
import JavaScriptCore
import Darwin

/// Runs in the short-lived plugin worker, never in the device service.
public enum PluginHost {
    public static func run(kind: String, path: String, request: String) throws -> String {
        guard request.utf8.count <= 65536 else { throw ConfigError("プラグイン入力が大きすぎます") }
        switch kind {
        case "dylib":
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw ConfigError(String(cString: dlerror())) }
            defer { dlclose(handle) }
            guard let address = dlsym(handle, "dial_plugin_run") else { throw ConfigError("dial_plugin_run がありません") }
            typealias Run = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
            let run = unsafeBitCast(address, to: Run.self)
            guard let result = request.withCString({ run($0) }) else { throw ConfigError("プラグインが結果を返しませんでした") }
            let size = strnlen(result, 65537)
            guard size <= 65536 else { throw ConfigError("プラグインの結果が大きすぎます") }
            return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(result).assumingMemoryBound(to: UInt8.self), count: size), as: UTF8.self)
        case "wasm":
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count <= 8 * 1024 * 1024 else { throw ConfigError("Wasmモジュールが大きすぎます") }
            let context = JSContext()!
            let moduleBytes = data.map(String.init).joined(separator: ",")
            let inputBytes = request.utf8.map(String.init).joined(separator: ",")
            let script = """
            const bytes = new Uint8Array([\(moduleBytes)]);
            const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
            const e = instance.exports;
            if (!(e.memory instanceof WebAssembly.Memory) || typeof e.dial_alloc !== 'function' || typeof e.dial_run !== 'function' || typeof e.dial_result_len !== 'function') throw new Error('Missing plugin ABI exports');
            const input = new Uint8Array([\(inputBytes)]);
            const inputPtr = e.dial_alloc(input.length) >>> 0;
            if (inputPtr + input.length > e.memory.buffer.byteLength) throw new Error('Invalid input buffer');
            new Uint8Array(e.memory.buffer, inputPtr, input.length).set(input);
            const outPtr = e.dial_run(inputPtr, input.length) >>> 0;
            const outLen = e.dial_result_len() >>> 0;
            if (outLen > 65536 || outPtr + outLen > e.memory.buffer.byteLength) throw new Error('Invalid output buffer');
            Array.from(new Uint8Array(e.memory.buffer, outPtr, outLen));
            """
            let value = context.evaluateScript(script)
            if let exception = context.exception { throw ConfigError("Wasm: \(exception.toString() ?? "error")") }
            guard let bytes = value?.toArray() as? [NSNumber] else { throw ConfigError("Wasmが結果を返しませんでした") }
            return String(decoding: bytes.map(\.uint8Value), as: UTF8.self)
        default: throw ConfigError("未対応のプラグイン形式です")
        }
    }
}
