# dxc-build

Zig build script that builds the DirectX Shader Compiler (DXC) from source. Artifacts are built for Windows, Linux, and macOS which can be found https://github.com/vinterbell/dxc-build/releases/tag/v1.8.2505.

tracking commit 85f7653650f44c32c0853d77b68348d366d90a26 of dxc upstream.

## Building
```sh
zig build
```
You will end up with dxcompiler, dxil and dxc binaries in `zig-out/bin/`.