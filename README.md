# dxc-build

Zig build script that builds the DirectX Shader Compiler (DXC) from source. Artifacts are built for Windows, Linux, and macOS which can be found https://github.com/vinterbell/dxc-build/releases/tag/v1.8.2505.

tracking commit b1cf2cad8f19f2ce733bd108e63485b33fbd4774 of dxc upstream.

## Building
```sh
zig build
```
You will end up with dxcompiler, dxil and dxc binaries in `zig-out/bin/`.