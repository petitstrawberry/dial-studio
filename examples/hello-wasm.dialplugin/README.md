# Hello Wasm

With a WebAssembly-enabled Clang and `wasm-ld`, build the module in this folder:

```sh
clang --target=wasm32 -O2 -nostdlib hello.c -o hello.wasm \
  -Wl,--no-entry -Wl,--export-memory \
  -Wl,--export=dial_alloc -Wl,--export=dial_run -Wl,--export=dial_result_len
```

Add the folder in Dial Studio's plugin settings. See [plugin development](../../docs/plugins.md) for the request and response format.
