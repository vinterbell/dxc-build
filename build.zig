const std = @import("std");

const cxx_flags: []const []const u8 = &.{
    "-std=c++17",                "-Wno-unused-command-line-argument",
    "-Wno-unused-variable",      "-Wno-missing-exception-spec",
    "-Wno-macro-redefined",      "-Wno-unknown-attributes",
    "-Wno-implicit-fallthrough", "-Wno-invalid-specialization",
    "-fms-extensions",           "-Wno-switch-enum",
};

const include_extensions: []const []const u8 = &.{
    "h",
    "inc",
    "def",
    "inl",
    "gen",
    "hpp",
    "hpp11",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.abi == .musl) {
        std.debug.panic("DXC does not support musl (requires dynamic linking).\n", .{});
        return;
    }

    const upstream = b.dependency("upstream", .{});

    const spirv_headers_dep = b.dependency("spirv_headers", .{});
    const spirv_tools = try buildSpirvTools(b, target, optimize);

    const spirv_headers_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const spirv_headers = b.addLibrary(.{
        .name = "spirv_headers",
        .root_module = spirv_headers_module,
    });
    spirv_headers.installHeadersDirectory(spirv_headers_dep.path("include"), "", .{
        .include_extensions = include_extensions,
    });

    const directx_headers_dep = b.dependency("directx_headers", .{});
    const directx_headers_path = directx_headers_dep.path("directx");
    const wsl_stubs_path = directx_headers_dep.path("wsl/stubs");

    const include_dir = upstream.path("include");
    const lib_path = upstream.path("lib");
    const clang_include_dir = upstream.path("tools/clang/include");
    const clang_lib_path = upstream.path("tools/clang/lib");

    const llvm_root_module = b.addModule("dxc_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    const lib = b.addLibrary(.{
        .name = "llvm",
        .root_module = llvm_root_module,
    });

    llvm_root_module.addIncludePath(include_dir);
    llvm_root_module.addIncludePath(b.path("generated"));
    if (target.result.os.tag != .windows) {
        llvm_root_module.addAfterIncludePath(directx_headers_path);
        llvm_root_module.addAfterIncludePath(wsl_stubs_path);
    }
    llvm_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");

    const llvm_config_h: LLVMConfigH = .init(target.result);
    const config_h: CONFIG_H = .init(target.result, llvm_config_h);

    const config_headers: []const *std.Build.Step.ConfigHeader = &.{
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = include_dir.path(b, "llvm/Config/config.h.cmake"),
                },
                .include_path = "llvm/Config/config.h",
            },
            config_h,
        ),
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = include_dir.path(b, "llvm/Config/llvm-config.h.cmake"),
                },
                .include_path = "llvm/Config/llvm-config.h",
            },
            llvm_config_h,
        ),
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = include_dir.path(b, "llvm/Config/abi-breaking.h.cmake"),
                },
                .include_path = "llvm/Config/abi-breaking.h",
            },
            .{},
        ),
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = include_dir.path(b, "llvm/Support/DataTypes.h.cmake"),
                },
                .include_path = "llvm/Support/DataTypes.h",
            },
            .{
                .HAVE_INTTYPES_H = 1,
                .HAVE_STDINT_H = 1,
                .HAVE_U_INT64_T = 0,
                .HAVE_UINT64_T = 1,
            },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = clang_include_dir.path(b, "clang/Config/config.h.cmake") },
                .include_path = "clang/Config/config.h",
            },
            .{
                .BUG_REPORT_URL = null,
                .CLANG_DEFAULT_OPENMP_RUNTIME = null,
                .CLANG_LIBDIR_SUFFIX = null,
                .CLANG_RESOURCE_DIR = null,
                .C_INCLUDE_DIRS = null,
                .DEFAULT_SYSROOT = null,
                .GCC_INSTALL_PREFIX = null,
                .CLANG_HAVE_LIBXML = 0,
                .BACKEND_PACKAGE_STRING = null,
                .HOST_LINK_VERSION = null,
            },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = include_dir.path(b, "llvm/Config/AsmParsers.def.in") },
                .include_path = "llvm/Config/AsmParsers.def",
            },
            .{ .LLVM_ENUM_ASM_PARSERS = null },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = include_dir.path(b, "llvm/Config/AsmPrinters.def.in") },
                .include_path = "llvm/Config/AsmPrinters.def",
            },
            .{ .LLVM_ENUM_ASM_PRINTERS = null },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = include_dir.path(b, "llvm/Config/Disassemblers.def.in") },
                .include_path = "llvm/Config/Disassemblers.def",
            },
            .{ .LLVM_ENUM_DISASSEMBLERS = null },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = include_dir.path(b, "llvm/Config/Targets.def.in") },
                .include_path = "llvm/Config/Targets.def",
            },
            .{ .LLVM_ENUM_TARGETS = null },
        ),
        b.addConfigHeader(
            .{
                // .style = .{ .cmake = include_dir.path(b, "dxc/config.h.cmake") },
                .style = .{ .cmake = b.path("config/dxc-config.h.cmake") },
                .include_path = "dxc/config.h",
            },
            .{
                .DXC_DISABLE_ALLOCATOR_OVERRIDES = false,
            },
        ),
        b.addConfigHeader(
            .{
                .style = .{ .cmake = upstream.path("lib/DxcSupport/SharedLibAffix.inc") },
                .include_path = "dxc/Support/SharedLibAffix.h",
            },
            .{
                .CMAKE_SHARED_LIBRARY_PREFIX = switch (target.result.os.tag) {
                    .windows => "",
                    else => "lib",
                },
                .CMAKE_SHARED_LIBRARY_SUFFIX = switch (target.result.os.tag) {
                    .windows => ".dll",
                    .macos => ".dylib",
                    else => ".so",
                },
            },
        ),
    };
    for (config_headers) |config_header| {
        llvm_root_module.addConfigHeader(config_header);
    }
    for (config_headers) |config_header| {
        lib.installConfigHeader(config_header);
    }

    inline for (@typeInfo(sources).@"struct".decls) |decl| {
        llvm_root_module.addCSourceFiles(.{
            .files = @field(sources, decl.name),
            .root = lib_path.path(b, decl.name),
            .flags = cxx_flags,
        });
    }

    inline for (@typeInfo(sources_c).@"struct".decls) |decl| {
        llvm_root_module.addCSourceFiles(.{
            .files = @field(sources_c, decl.name),
            .root = lib_path.path(b, decl.name),
            .flags = &.{
                "-std=c11",                  "-Wno-unused-command-line-argument",
                "-Wno-unused-variable",      "-Wno-missing-exception-spec",
                "-Wno-macro-redefined",      "-Wno-unknown-attributes",
                "-Wno-implicit-fallthrough", "-Wno-invalid-specialization",
                "-fms-extensions",
            },
        });
    }

    lib.installHeadersDirectory(include_dir, "", .{
        .include_extensions = include_extensions,
    });
    lib.installHeadersDirectory(b.path("generated"), "", .{
        .include_extensions = include_extensions,
    });
    if (target.result.os.tag != .windows) {
        lib.installHeadersDirectory(directx_headers_path, "", .{
            .include_extensions = include_extensions,
        });
        lib.installHeadersDirectory(wsl_stubs_path, "", .{
            .include_extensions = include_extensions,
        });
    }

    const clang_root_module = b.addModule("clang_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    clang_root_module.addIncludePath(clang_include_dir);
    clang_root_module.addIncludePath(b.path("generated"));
    clang_root_module.linkLibrary(lib);
    clang_root_module.linkLibrary(spirv_tools);
    clang_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");

    const clang = b.addLibrary(.{
        .name = "clang",
        .root_module = clang_root_module,
    });
    clang.installHeadersDirectory(clang_include_dir, "", .{
        .include_extensions = include_extensions,
    });
    clang.installHeadersDirectory(b.path("generated"), "", .{
        .include_extensions = include_extensions,
    });

    inline for (@typeInfo(clang_sources).@"struct".decls) |decl| {
        clang_root_module.addCSourceFiles(.{
            .files = @field(clang_sources, decl.name),
            .root = clang_lib_path.path(b, decl.name),
            .flags = cxx_flags,
        });
    }

    const libclang_path = upstream.path("tools/clang/tools/libclang");
    const libclang_root_module = b.addModule("libclang_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    libclang_root_module.addCSourceFiles(.{
        .root = libclang_path,
        .files = &.{
            "CIndex.cpp",
            "CIndexCXX.cpp",
            "CIndexCodeCompletion.cpp",
            "CIndexDiagnostic.cpp",
            "CIndexHigh.cpp",
            "CIndexInclusionStack.cpp",
            "CIndexUSRs.cpp",
            "CIndexer.cpp",
            "CXComment.cpp",
            "CXCursor.cpp",
            "CXCompilationDatabase.cpp",
            "CXLoadedDiagnostic.cpp",
            "CXSourceLocation.cpp",
            "CXStoredDiagnostic.cpp",
            "CXString.cpp",
            "CXType.cpp",
            "IndexBody.cpp",
            "IndexDecl.cpp",
            "IndexTypeSourceInfo.cpp",
            "Indexing.cpp",
            "IndexingContext.cpp",
            "dxcisenseimpl.cpp", // HLSL Change
            "dxcrewriteunused.cpp", // HLSL Change
        },
        .flags = cxx_flags,
    });
    libclang_root_module.linkLibrary(clang);
    libclang_root_module.linkLibrary(lib);
    libclang_root_module.linkLibrary(spirv_tools);
    libclang_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");

    const libclang = b.addLibrary(.{
        .name = "libclang",
        .root_module = libclang_root_module,
    });

    const validator_path = upstream.path("tools/clang/tools/dxcvalidator");

    const validator_root_module = b.addModule("dxcvalidator_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    validator_root_module.addCSourceFiles(.{
        .root = validator_path,
        .files = &.{
            "dxcvalidator.cpp",
        },
        .flags = cxx_flags,
    });
    validator_root_module.addIncludePath(validator_path);
    validator_root_module.linkLibrary(lib);
    validator_root_module.linkLibrary(clang);
    validator_root_module.linkLibrary(spirv_tools);
    validator_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");

    const dxcvalidator = b.addLibrary(.{
        .name = "dxcvalidator",
        .root_module = validator_root_module,
    });
    dxcvalidator.installHeadersDirectory(validator_path, "", .{
        .include_extensions = include_extensions,
    });

    const compiler_root_module = b.addModule("dxcompiler_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    compiler_root_module.addCSourceFiles(.{
        .root = upstream.path("tools/clang/tools/dxcompiler"),
        .files = &.{
            "dxcapi.cpp",
            "dxcassembler.cpp",
            "dxclibrary.cpp",
            "dxcompilerobj.cpp",
            "DXCompiler.cpp",
            "dxcfilesystem.cpp",
            "dxcutil.cpp",
            "dxcdisassembler.cpp",
            "dxcpdbutils.cpp",
            "dxcvalidator.cpp",
            "dxclinker.cpp",
            "dxcshadersourceinfo.cpp",
        },
        .flags = cxx_flags,
    });
    compiler_root_module.linkLibrary(lib);
    compiler_root_module.linkLibrary(libclang);
    compiler_root_module.linkLibrary(clang);
    compiler_root_module.linkLibrary(dxcvalidator);
    compiler_root_module.linkLibrary(spirv_tools);
    if (target.result.os.tag == .windows) {
        compiler_root_module.linkSystemLibrary("Version", .{});
        compiler_root_module.linkSystemLibrary("Ole32", .{});
        compiler_root_module.linkSystemLibrary("OleAut32", .{});
    }
    compiler_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");
    compiler_root_module.addCMacro("DXC_API_IMPORT", "__declspec(dllexport)");

    const compiler = b.addLibrary(.{
        .name = "dxcompiler",
        .root_module = compiler_root_module,
        .linkage = .dynamic,
    });
    compiler.installLibraryHeaders(lib);
    compiler.installLibraryHeaders(dxcvalidator);

    b.installArtifact(compiler);

    const dxclib_path = upstream.path("tools/clang/tools/dxclib");
    const dxclib_executable_root_module = b.addModule("dxclib_executable_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    dxclib_executable_root_module.addCSourceFiles(.{
        .root = dxclib_path,
        .files = &.{
            "dxc.cpp",
        },
        .flags = cxx_flags,
    });
    dxclib_executable_root_module.linkLibrary(lib);
    dxclib_executable_root_module.linkLibrary(libclang);
    dxclib_executable_root_module.linkLibrary(clang);
    dxclib_executable_root_module.linkLibrary(dxcvalidator);
    dxclib_executable_root_module.linkLibrary(spirv_tools);
    dxclib_executable_root_module.addCMacro("ENABLE_SPIRV_CODEGEN", "1");

    const dxclib_lib = b.addLibrary(.{
        .name = "dxclib",
        .root_module = dxclib_executable_root_module,
    });
    dxclib_lib.installLibraryHeaders(compiler);
    dxclib_lib.installHeadersDirectory(dxclib_path, "dxclib", .{
        .include_extensions = include_extensions,
    });

    const dxc_exe_path = upstream.path("tools/clang/tools/dxc");
    const dxc_exe_root_module = b.addModule("dxc_exe_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    dxc_exe_root_module.linkLibrary(dxclib_lib);
    dxc_exe_root_module.addCSourceFiles(.{
        .root = dxc_exe_path,
        .files = &.{
            "dxcmain.cpp",
        },
        .flags = cxx_flags,
    });
    if (target.result.os.tag == .windows) {
        dxc_exe_root_module.linkSystemLibrary("Version", .{});
        dxc_exe_root_module.linkSystemLibrary("Ole32", .{});
        dxc_exe_root_module.linkSystemLibrary("OleAut32", .{});
    }

    const dxc = b.addExecutable(.{
        .name = "dxc",
        .root_module = dxc_exe_root_module,
    });
    b.installArtifact(dxc);
    dxc.mingw_unicode_entry_point = true;

    const dxil_path = upstream.path("tools/clang/tools/dxildll");
    const dxil_root_module = b.addModule("dxil_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    dxil_root_module.addCSourceFiles(.{
        .root = dxil_path,
        .files = &.{
            "dxildll.cpp",
            "dxcvalidator.cpp",
        },
        .flags = cxx_flags,
    });
    dxil_root_module.linkLibrary(lib);
    dxil_root_module.linkLibrary(clang);
    dxil_root_module.linkLibrary(dxcvalidator);
    if (target.result.os.tag == .windows) {
        dxil_root_module.linkSystemLibrary("Version", .{});
        dxil_root_module.linkSystemLibrary("Ole32", .{});
        dxil_root_module.linkSystemLibrary("OleAut32", .{});
    }
    dxil_root_module.addCMacro("DXC_API_IMPORT", "__declspec(dllexport)");

    const dxil = b.addLibrary(.{
        .name = "dxil",
        .root_module = dxil_root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(dxil);

    const version = try Version.init(b);
    const version_step = b.step("version", "Get build version");
    version_step.dependOn(&version.step);
}

pub const sources = struct {
    pub const Analysis: []const []const u8 = @import("sources/Analysis.zon");
    pub const AsmParser: []const []const u8 = @import("sources/AsmParser.zon");
    pub const Bitcode: []const []const u8 = @import("sources/Bitcode.zon");
    pub const DxcBindingTable: []const []const u8 = @import("sources/DxcBindingTable.zon");
    pub const DxcSupport: []const []const u8 = @import("sources/DxcSupport.zon");
    pub const DXIL: []const []const u8 = @import("sources/DXIL.zon");
    pub const DxilCompression: []const []const u8 = @import("sources/DxilCompression.zon");
    pub const DxilContainer: []const []const u8 = @import("sources/DxilContainer.zon");
    pub const DxilDia: []const []const u8 = @import("sources/DxilDia.zon");
    pub const DxilHash: []const []const u8 = @import("sources/DxilHash.zon");
    pub const DxilPdbInfo: []const []const u8 = @import("sources/DxilPdbInfo.zon");
    pub const DxilPIXPasses: []const []const u8 = @import("sources/DxilPIXPasses.zon");
    pub const DxilRootSignature: []const []const u8 = @import("sources/DxilRootSignature.zon");
    pub const DxilValidation: []const []const u8 = @import("sources/DxilValidation.zon");
    pub const DxrFallback: []const []const u8 = @import("sources/DxrFallback.zon");
    pub const HLSL: []const []const u8 = @import("sources/HLSL.zon");
    pub const IR: []const []const u8 = @import("sources/IR.zon");
    pub const IRReader: []const []const u8 = @import("sources/IRReader.zon");
    pub const Linker: []const []const u8 = @import("sources/Linker.zon");
    pub const MSSupport: []const []const u8 = @import("sources/MSSupport.zon");
    pub const Option: []const []const u8 = @import("sources/Option.zon");
    pub const Passes: []const []const u8 = @import("sources/Passes.zon");
    pub const PassPrinters: []const []const u8 = @import("sources/PassPrinters.zon");
    pub const ProfileData: []const []const u8 = @import("sources/ProfileData.zon");
    pub const Support: []const []const u8 = @import("sources/Support.zon");
    pub const TableGen: []const []const u8 = @import("sources/TableGen.zon");
    pub const Target: []const []const u8 = @import("sources/Target.zon");
    pub const Transforms: []const []const u8 = @import("sources/Transforms.zon");
};

pub const sources_c = struct {
    pub const DxilCompression: []const []const u8 = @import("sources/DxilCompression-c.zon");
    pub const Support: []const []const u8 = @import("sources/Support-c.zon");
};

const LLVMConfigH = struct {
    LLVM_BINDIR: ?[]const u8 = null,
    LLVM_CONFIGTIME: ?[]const u8 = null,
    LLVM_DATADIR: ?[]const u8 = null,
    LLVM_DEFAULT_TARGET_TRIPLE: []const u8,
    LLVM_DOCSDIR: ?[]const u8 = null,
    LLVM_ENABLE_THREADS: ?i64 = null,
    LLVM_ETCDIR: ?[]const u8 = null,
    LLVM_HAS_ATOMICS: ?i64 = null,
    LLVM_HOST_TRIPLE: []const u8 = "",
    LLVM_INCLUDEDIR: ?[]const u8 = null,
    LLVM_INFODIR: ?[]const u8 = null,
    LLVM_MANDIR: ?[]const u8 = null,
    LLVM_NATIVE_ARCH: []const u8 = "",
    LLVM_ON_UNIX: ?i64 = null,
    LLVM_ON_WIN32: ?i64 = null,
    LLVM_PREFIX: []const u8,
    LLVM_VERSION_MAJOR: u8,
    LLVM_VERSION_MINOR: u8,
    LLVM_VERSION_PATCH: u8,
    PACKAGE_VERSION: []const u8,

    pub fn init(target: std.Target) LLVMConfigH {
        var llvm_config_h: LLVMConfigH = .{
            .LLVM_PREFIX = "/usr/local",
            .LLVM_DEFAULT_TARGET_TRIPLE = "dxil-ms-dx",
            .LLVM_ENABLE_THREADS = 1,
            .LLVM_HAS_ATOMICS = 1,
            .LLVM_HOST_TRIPLE = "",
            .LLVM_VERSION_MAJOR = 3,
            .LLVM_VERSION_MINOR = 7,
            .LLVM_VERSION_PATCH = 0,
            .PACKAGE_VERSION = "3.7-v1.4.0.2274-1812-g84da60c6c-dirty",
        };
        if (target.os.tag == .windows) {
            llvm_config_h.LLVM_ON_WIN32 = 1;
            switch (target.abi) {
                .msvc => switch (target.cpu.arch) {
                    .x86_64 => llvm_config_h.LLVM_HOST_TRIPLE = "x86_64-w64-msvc",
                    .aarch64 => llvm_config_h.LLVM_HOST_TRIPLE = "aarch64-w64-msvc",
                    else => @panic("target architecture not supported"),
                },
                .gnu => switch (target.cpu.arch) {
                    .x86_64 => llvm_config_h.LLVM_HOST_TRIPLE = "x86_64-w64-mingw32",
                    .aarch64 => llvm_config_h.LLVM_HOST_TRIPLE = "aarch64-w64-mingw32",
                    else => @panic("target architecture not supported"),
                },
                else => @panic("target ABI not supported"),
            }
        } else if (target.os.tag.isDarwin()) {
            llvm_config_h.LLVM_ON_UNIX = 1;
            switch (target.cpu.arch) {
                .aarch64 => llvm_config_h.LLVM_HOST_TRIPLE = "aarch64-apple-darwin",
                .x86_64 => llvm_config_h.LLVM_HOST_TRIPLE = "x86_64-apple-darwin",
                else => @panic("target architecture not supported"),
            }
        } else {
            // Assume linux-like
            // TODO: musl support?
            llvm_config_h.LLVM_ON_UNIX = 1;
            switch (target.cpu.arch) {
                .aarch64 => llvm_config_h.LLVM_HOST_TRIPLE = "aarch64-linux-gnu",
                .x86_64 => llvm_config_h.LLVM_HOST_TRIPLE = "x86_64-linux-gnu",
                else => @panic("target architecture not supported"),
            }
        }
        return llvm_config_h;
    }
};

const CONFIG_H = struct {
    BUG_REPORT_URL: []const u8 = "http://llvm.org/bugs/",
    ENABLE_BACKTRACES: []const u8 = "",
    ENABLE_CRASH_OVERRIDES: []const u8 = "",
    DISABLE_LLVM_DYLIB_ATEXIT: []const u8 = "",
    ENABLE_PIC: []const u8 = "",
    ENABLE_TIMESTAMPS: ?i64 = null,
    HAVE_DECL_ARC4RANDOM: ?i64 = null,
    HAVE_BACKTRACE: ?i64 = null,
    HAVE_CLOSEDIR: ?i64 = null,
    HAVE_CXXABI_H: ?i64 = null,
    HAVE_DECL_STRERROR_S: ?i64 = null,
    HAVE_DIRENT_H: ?i64 = null,
    HAVE_DIA_SDK: ?i64 = null,
    HAVE_DLERROR: ?i64 = null,
    HAVE_DLFCN_H: ?i64 = null,
    HAVE_DLOPEN: ?i64 = null,
    HAVE_ERRNO_H: ?i64 = null,
    HAVE_EXECINFO_H: ?i64 = null,
    HAVE_FCNTL_H: ?i64 = null,
    HAVE_FENV_H: ?i64 = null,
    HAVE_FFI_CALL: ?i64 = null,
    HAVE_FFI_FFI_H: ?i64 = null,
    HAVE_FFI_H: ?i64 = null,
    HAVE_FUTIMENS: ?i64 = null,
    HAVE_FUTIMES: ?i64 = null,
    HAVE_GETCWD: ?i64 = null,
    HAVE_GETPAGESIZE: ?i64 = null,
    HAVE_GETRLIMIT: ?i64 = null,
    HAVE_GETRUSAGE: ?i64 = null,
    HAVE_GETTIMEOFDAY: ?i64 = null,
    HAVE_INT64_T: ?i64 = null,
    HAVE_INTTYPES_H: ?i64 = null,
    HAVE_ISATTY: ?i64 = null,
    HAVE_LIBDL: ?i64 = null,
    HAVE_LIBEDIT: ?i64 = null,
    HAVE_LIBPSAPI: ?i64 = null,
    HAVE_LIBPTHREAD: ?i64 = null,
    HAVE_LIBSHELL32: ?i64 = null,
    HAVE_LIBZ: ?i64 = null,
    HAVE_LIMITS_H: ?i64 = null,
    HAVE_LINK_EXPORT_DYNAMIC: ?i64 = null,
    HAVE_LINK_H: ?i64 = null,
    HAVE_LONGJMP: ?i64 = null,
    HAVE_MACH_MACH_H: ?i64 = null,
    HAVE_MACH_O_DYLD_H: ?i64 = null,
    HAVE_MALLCTL: ?i64 = null,
    HAVE_MALLINFO: ?i64 = null,
    HAVE_MALLINFO2: ?i64 = null,
    HAVE_MALLOC_H: ?i64 = null,
    HAVE_MALLOC_MALLOC_H: ?i64 = null,
    HAVE_MALLOC_ZONE_STATISTICS: ?i64 = null,
    HAVE_MKDTEMP: ?i64 = null,
    HAVE_MKSTEMP: ?i64 = null,
    HAVE_MKTEMP: ?i64 = null,
    HAVE_NDIR_H: ?i64 = null,
    HAVE_OPENDIR: ?i64 = null,
    HAVE_POSIX_SPAWN: ?i64 = null,
    HAVE_PREAD: ?i64 = null,
    HAVE_PTHREAD_GETSPECIFIC: ?i64 = null,
    HAVE_PTHREAD_H: ?i64 = null,
    HAVE_PTHREAD_MUTEX_LOCK: ?i64 = null,
    HAVE_PTHREAD_RWLOCK_INIT: ?i64 = null,
    HAVE_RAND48: ?i64 = null,
    HAVE_READDIR: ?i64 = null,
    HAVE_REALPATH: ?i64 = null,
    HAVE_SBRK: ?i64 = null,
    HAVE_SETENV: ?i64 = null,
    HAVE_SETJMP: ?i64 = null,
    HAVE_SETRLIMIT: ?i64 = null,
    HAVE_SIGLONGJMP: ?i64 = null,
    HAVE_SIGNAL_H: ?i64 = null,
    HAVE_SIGSETJMP: ?i64 = null,
    HAVE_STDINT_H: ?i64 = null,
    HAVE_STRDUP: ?i64 = null,
    HAVE_STRERROR_R: ?i64 = null,
    HAVE_STRERROR: ?i64 = null,
    HAVE_STRTOLL: ?i64 = null,
    HAVE_STRTOQ: ?i64 = null,
    HAVE_SYS_DIR_H: ?i64 = null,
    HAVE_SYS_IOCTL_H: ?i64 = null,
    HAVE_SYS_MMAN_H: ?i64 = null,
    HAVE_SYS_NDIR_H: ?i64 = null,
    HAVE_SYS_PARAM_H: ?i64 = null,
    HAVE_SYS_RESOURCE_H: ?i64 = null,
    HAVE_SYS_STAT_H: ?i64 = null,
    HAVE_SYS_TIME_H: ?i64 = null,
    HAVE_SYS_TYPES_H: ?i64 = null,
    HAVE_SYS_UIO_H: ?i64 = null,
    HAVE_SYS_WAIT_H: ?i64 = null,
    HAVE_TERMINFO: ?i64 = null,
    HAVE_TERMIOS_H: ?i64 = null,
    HAVE_UINT64_T: ?i64 = null,
    HAVE_UNISTD_H: ?i64 = null,
    HAVE_UTIME_H: ?i64 = null,
    HAVE_U_INT64_T: ?i64 = null,
    HAVE_VALGRIND_VALGRIND_H: ?i64 = null,
    HAVE_WRITEV: ?i64 = null,
    HAVE_ZLIB_H: ?i64 = null,
    HAVE__ALLOCA: ?i64 = null,
    HAVE___ALLOCA: ?i64 = null,
    HAVE___ASHLDI3: ?i64 = null,
    HAVE___ASHRDI3: ?i64 = null,
    HAVE___CHKSTK: ?i64 = null,
    HAVE___CHKSTK_MS: ?i64 = null,
    HAVE___CMPDI2: ?i64 = null,
    HAVE___DIVDI3: ?i64 = null,
    HAVE___FIXDFDI: ?i64 = null,
    HAVE___FIXSFDI: ?i64 = null,
    HAVE___FLOATDIDF: ?i64 = null,
    HAVE___LSHRDI3: ?i64 = null,
    HAVE___MAIN: ?i64 = null,
    HAVE___MODDI3: ?i64 = null,
    HAVE___UDIVDI3: ?i64 = null,
    HAVE___UMODDI3: ?i64 = null,
    HAVE____CHKSTK: ?i64 = null,
    HAVE____CHKSTK_MS: ?i64 = null,
    LLVM_BINDIR: ?[]const u8 = null,
    LLVM_CONFIGTIME: ?[]const u8 = null,
    LLVM_DATADIR: ?[]const u8 = null,
    LLVM_DEFAULT_TARGET_TRIPLE: []const u8,
    LLVM_DOCSDIR: ?[]const u8 = null,
    LLVM_ENABLE_THREADS: ?i64 = null,
    LLVM_ENABLE_ZLIB: ?i64 = null,
    LLVM_ETCDIR: ?[]const u8 = null,
    LLVM_HAS_ATOMICS: ?i64 = null,
    LLVM_HOST_TRIPLE: []const u8 = "",
    LLVM_INCLUDEDIR: ?[]const u8 = null,
    LLVM_INFODIR: ?[]const u8 = null,
    LLVM_MANDIR: ?[]const u8 = null,
    LLVM_NATIVE_ARCH: []const u8 = "",
    LLVM_ON_UNIX: ?i64 = null,
    LLVM_ON_WIN32: ?i64 = null,
    LLVM_PREFIX: []const u8,
    LLVM_VERSION_MAJOR: u8,
    LLVM_VERSION_MINOR: u8,
    LLVM_VERSION_PATCH: u8,

    // LTDL_... isn't an i64, but we don't use them and I am unsure
    // what type is more appropriate.
    LTDL_DLOPEN_DEPLIBS: ?i64 = null,
    LTDL_SHLIB_EXT: ?i64 = null,
    LTDL_SYSSEARCHPATH: ?i64 = null,

    PACKAGE_BUGREPORT: []const u8 = "http://llvm.org/bugs/",
    PACKAGE_NAME: []const u8 = "LLVM",
    PACKAGE_STRING: []const u8 = "LLVM 3.7-v1.4.0.2274-1812-g84da60c6c-dirty",
    PACKAGE_VERSION: []const u8,
    RETSIGTYPE: []const u8 = "void",
    WIN32_ELMCB_PCSTR: []const u8 = "PCSTR",

    // str... isn't an i64, but we don't use them and I am unsure
    // what type is more appropriate. Perhaps a function pointer?
    strtoll: ?i64 = null,
    strtoull: ?i64 = null,
    stricmp: ?i64 = null,
    strdup: ?i64 = null,

    HAVE__CHSIZE_S: ?i64 = null,

    pub fn init(target: std.Target, llvm_config_h: LLVMConfigH) CONFIG_H {
        const tag = target.os.tag;
        const if_windows: ?i64 = if (tag == .windows) 1 else null;
        const if_not_windows: ?i64 = if (tag == .windows) null else 1;
        const if_windows_or_linux: ?i64 = if (tag == .windows and !tag.isDarwin()) 1 else null;
        const if_darwin: ?i64 = if (tag.isDarwin()) 1 else null;
        const if_not_msvc: ?i64 = if (target.abi != .msvc) 1 else null;
        const config_h = CONFIG_H{
            .HAVE_STRERROR = if_windows,
            .HAVE_STRERROR_R = if_not_windows,
            .HAVE_MALLOC_H = if_windows_or_linux,
            .HAVE_MALLOC_MALLOC_H = if_darwin,
            .HAVE_MALLOC_ZONE_STATISTICS = if_not_windows,
            .HAVE_GETPAGESIZE = if_not_windows,
            .HAVE_PTHREAD_H = if_not_windows,
            .HAVE_PTHREAD_GETSPECIFIC = if_not_windows,
            .HAVE_PTHREAD_MUTEX_LOCK = if_not_windows,
            .HAVE_PTHREAD_RWLOCK_INIT = if_not_windows,
            .HAVE_DLOPEN = if_not_windows,
            .HAVE_DLFCN_H = if_not_windows, //
            .HAVE_UNISTD_H = if_not_msvc,
            .HAVE_SYS_MMAN_H = if_not_windows,

            .ENABLE_TIMESTAMPS = 1,
            .HAVE_CLOSEDIR = 1,
            .HAVE_CXXABI_H = 1,
            .HAVE_DECL_STRERROR_S = 1,
            .HAVE_DIRENT_H = 1,
            .HAVE_ERRNO_H = 1,
            .HAVE_FCNTL_H = 1,
            .HAVE_FENV_H = 1,
            .HAVE_GETCWD = 1,
            .HAVE_GETTIMEOFDAY = 1,
            .HAVE_INT64_T = 1,
            .HAVE_INTTYPES_H = 1,
            .HAVE_ISATTY = 1,
            .HAVE_LIBPSAPI = 1,
            .HAVE_LIBSHELL32 = 1,
            .HAVE_LIMITS_H = 1,
            .HAVE_LINK_EXPORT_DYNAMIC = 1,
            .HAVE_MKSTEMP = 1,
            .HAVE_MKTEMP = 1,
            .HAVE_OPENDIR = 1,
            .HAVE_READDIR = 1,
            .HAVE_SIGNAL_H = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_STRTOLL = 1,
            .HAVE_SYS_PARAM_H = 1,
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_UINT64_T = 1,
            .HAVE_UTIME_H = 1,
            .HAVE__ALLOCA = 1,
            .HAVE___ASHLDI3 = 1,
            .HAVE___ASHRDI3 = 1,
            .HAVE___CMPDI2 = 1,
            .HAVE___DIVDI3 = 1,
            .HAVE___FIXDFDI = 1,
            .HAVE___FIXSFDI = 1,
            .HAVE___FLOATDIDF = 1,
            .HAVE___LSHRDI3 = 1,
            .HAVE___MAIN = 1,
            .HAVE___MODDI3 = 1,
            .HAVE___UDIVDI3 = 1,
            .HAVE___UMODDI3 = 1,
            .HAVE____CHKSTK_MS = 1,

            .LLVM_DEFAULT_TARGET_TRIPLE = llvm_config_h.LLVM_DEFAULT_TARGET_TRIPLE,
            .LLVM_ENABLE_THREADS = llvm_config_h.LLVM_ENABLE_THREADS,
            .LLVM_ENABLE_ZLIB = 0,
            .LLVM_HAS_ATOMICS = llvm_config_h.LLVM_HAS_ATOMICS,
            .LLVM_HOST_TRIPLE = llvm_config_h.LLVM_HOST_TRIPLE,
            .LLVM_ON_UNIX = llvm_config_h.LLVM_ON_UNIX,
            .LLVM_ON_WIN32 = llvm_config_h.LLVM_ON_WIN32,
            .LLVM_PREFIX = llvm_config_h.LLVM_PREFIX,
            .LLVM_VERSION_MAJOR = llvm_config_h.LLVM_VERSION_MAJOR,
            .LLVM_VERSION_MINOR = llvm_config_h.LLVM_VERSION_MINOR,
            .LLVM_VERSION_PATCH = llvm_config_h.LLVM_VERSION_PATCH,
            .PACKAGE_VERSION = llvm_config_h.PACKAGE_VERSION,

            .HAVE__CHSIZE_S = 1,
        };
        return config_h;
    }
};

pub const clang_sources = struct {
    pub const Analysis: []const []const u8 = @import("clang_sources/Analysis.zon");
    pub const AST: []const []const u8 = @import("clang_sources/AST.zon");
    pub const ASTMatchers: []const []const u8 = @import("clang_sources/ASTMatchers.zon");
    pub const Basic: []const []const u8 = @import("clang_sources/Basic.zon");
    pub const CodeGen: []const []const u8 = @import("clang_sources/CodeGen.zon");
    pub const Driver: []const []const u8 = @import("clang_sources/Driver.zon");
    pub const Edit: []const []const u8 = @import("clang_sources/Edit.zon");
    pub const Format: []const []const u8 = @import("clang_sources/Format.zon");
    pub const Frontend: []const []const u8 = @import("clang_sources/Frontend.zon");
    pub const FrontendTool: []const []const u8 = @import("clang_sources/FrontendTool.zon");
    pub const Index: []const []const u8 = @import("clang_sources/Index.zon");
    pub const Lex: []const []const u8 = @import("clang_sources/Lex.zon");
    pub const Parse: []const []const u8 = @import("clang_sources/Parse.zon");
    pub const Rewrite: []const []const u8 = @import("clang_sources/Rewrite.zon");
    pub const Sema: []const []const u8 = @import("clang_sources/Sema.zon");
    pub const SPIRV: []const []const u8 = @import("clang_sources/SPIRV.zon");
    pub const Tooling: []const []const u8 = @import("clang_sources/Tooling.zon");
};

fn buildSpirvTools(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Compile {
    const spirv_headers_dep = b.dependency("spirv_headers", .{});
    const spirv_tools_dep = b.dependency("spirv_tools", .{});
    const spirv_tools_root_module = b.addModule("spirv_tools_root", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    spirv_tools_root_module.addIncludePath(spirv_tools_dep.path("."));
    spirv_tools_root_module.addIncludePath(spirv_tools_dep.path("include"));
    spirv_tools_root_module.addIncludePath(spirv_headers_dep.path("include"));
    spirv_tools_root_module.addCSourceFiles(.{
        .root = spirv_tools_dep.path("source"),
        .files = spvtools_sources,
        .flags = cxx_flags,
    });
    spirv_tools_root_module.addCSourceFiles(.{
        .root = spirv_tools_dep.path("source/val"),
        .files = spvtools_val_sources,
        .flags = cxx_flags,
    });
    spirv_tools_root_module.addCSourceFiles(.{
        .root = spirv_tools_dep.path("source/opt"),
        .files = spvtools_opt_sources,
        .flags = cxx_flags,
    });
    spirv_tools_root_module.addCSourceFiles(.{
        .root = spirv_tools_dep.path("source/reduce"),
        .files = spvtools_reduce_sources,
        .flags = cxx_flags,
    });
    spirv_tools_root_module.addCSourceFiles(.{
        .root = spirv_tools_dep.path("source/link"),
        .files = spvtools_link_sources,
        .flags = cxx_flags,
    });

    const spirv_tools = b.addLibrary(.{
        .name = "spirv_tools",
        .root_module = spirv_tools_root_module,
    });
    const write_files = b.addWriteFiles();
    const new_include_folder = write_files.getDirectory();
    spirv_tools_root_module.addIncludePath(new_include_folder);

    spirv_tools.installHeadersDirectory(new_include_folder, "", .{
        .include_extensions = include_extensions,
    });
    spirv_tools.installHeadersDirectory(spirv_tools_dep.path("include"), "", .{
        .include_extensions = include_extensions,
    });
    spirv_tools.installHeadersDirectory(spirv_headers_dep.path("include"), "", .{
        .include_extensions = include_extensions,
    });

    const grammar_path = spirv_headers_dep.path("include/spirv/unified1");

    const generate_core_tables = try pythonCommand(b);
    generate_core_tables.addFileArg(spirv_tools_dep.path("utils/ggt.py"));
    generate_core_tables.addPrefixedFileArg("--spirv-core-grammar=", grammar_path.path(b, "spirv.core.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.debuginfo.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.glsl.std.450.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.nonsemantic.clspvreflection.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=SHDEBUG100_,", grammar_path.path(b, "extinst.nonsemantic.shader.debuginfo.100.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.nonsemantic.vkspreflection.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=CLDEBUG100_,", grammar_path.path(b, "extinst.opencl.debuginfo.100.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.opencl.std.100.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.spv-amd-gcn-shader.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.spv-amd-shader-ballot.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.spv-amd-shader-explicit-vertex-parameter.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--extinst=,", grammar_path.path(b, "extinst.spv-amd-shader-trinary-minmax.grammar.json"));
    generate_core_tables.addPrefixedFileArg("--core-tables-body-output=", new_include_folder.path(b, "core_tables_body.inc"));
    generate_core_tables.addPrefixedFileArg("--core-tables-header-output=", new_include_folder.path(b, "core_tables_header.inc"));

    const generate_generators_include = try pythonCommand(b);
    generate_generators_include.addFileArg(spirv_tools_dep.path("utils/generate_registry_tables.py"));
    generate_generators_include.addPrefixedFileArg("--xml=", spirv_headers_dep.path("include/spirv/spir-v.xml"));
    generate_generators_include.addPrefixedFileArg("--generator=", new_include_folder.path(b, "generators.inc"));

    const generate_build_version = try pythonCommand(b);
    generate_build_version.addFileArg(spirv_tools_dep.path("utils/update_build_version.py"));
    generate_build_version.addFileArg(spirv_tools_dep.path("CHANGES"));
    generate_build_version.addFileArg(new_include_folder.path(b, "build-version.inc"));

    const debug_info_header = try spvToolsLanguageHeader(
        b,
        new_include_folder.path(b, "DebugInfo.h"),
        grammar_path.path(b, "extinst.debuginfo.grammar.json"),
    );
    const opencl_debug_info_header = try spvToolsLanguageHeader(
        b,
        new_include_folder.path(b, "OpenCLDebugInfo100.h"),
        grammar_path.path(b, "extinst.opencl.debuginfo.100.grammar.json"),
    );
    const non_semantic_shader_debug_info_header = try spvToolsLanguageHeader(
        b,
        new_include_folder.path(b, "NonSemanticShaderDebugInfo100.h"),
        grammar_path.path(b, "extinst.nonsemantic.shader.debuginfo.100.grammar.json"),
    );

    const generate_step = b.step("generate_spirv_tools", "Generate SPIR-V Tools tables");
    generate_step.dependOn(&generate_core_tables.step);
    generate_step.dependOn(&generate_generators_include.step);
    generate_step.dependOn(&generate_build_version.step);
    generate_step.dependOn(debug_info_header);
    generate_step.dependOn(opencl_debug_info_header);
    generate_step.dependOn(non_semantic_shader_debug_info_header);

    spirv_tools.step.dependOn(generate_step);

    return spirv_tools;
}

fn spvToolsLanguageHeader(b: *std.Build, output: std.Build.LazyPath, grammar_file: std.Build.LazyPath) !*std.Build.Step {
    const spirv_tools_dep = b.dependency("spirv_tools", .{});

    const cmd = try pythonCommand(b);
    cmd.addFileArg(spirv_tools_dep.path("utils/generate_language_headers.py"));
    cmd.addPrefixedFileArg("--extinst-grammar=", grammar_file);
    cmd.addPrefixedFileArg("--extinst-output-path=", output);

    return &cmd.step;
}

// TODO: Use non-system python (allyourcodebase/cpython?, but it's not updated yet)
fn pythonCommand(b: *std.Build) !*std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{"py"});
    return cmd;
}

const spvtools_sources: []const []const u8 = &.{
    "assembly_grammar.cpp",
    "binary.cpp",
    "diagnostic.cpp",
    "disassemble.cpp",
    "ext_inst.cpp",
    "extensions.cpp",
    "libspirv.cpp",
    "name_mapper.cpp",
    "opcode.cpp",
    "operand.cpp",
    "parsed_operand.cpp",
    "print.cpp",
    "spirv_endian.cpp",
    "spirv_fuzzer_options.cpp",
    "spirv_optimizer_options.cpp",
    "spirv_reducer_options.cpp",
    "spirv_target_env.cpp",
    "spirv_validator_options.cpp",
    "table.cpp",
    "table2.cpp",
    "text.cpp",
    "text_handler.cpp",
    "to_string.cpp",
    "util/bit_vector.cpp",
    "util/parse_number.cpp",
    "util/string_utils.cpp",
    "util/timer.cpp",
};

const spvtools_val_sources: []const []const u8 = &.{
    "basic_block.cpp",
    "construct.cpp",
    "function.cpp",
    "instruction.cpp",
    "validate.cpp",
    "validate_adjacency.cpp",
    "validate_annotation.cpp",
    "validate_arithmetics.cpp",
    "validate_atomics.cpp",
    "validate_barriers.cpp",
    "validate_bitwise.cpp",
    "validate_builtins.cpp",
    "validate_capability.cpp",
    "validate_cfg.cpp",
    "validate_composites.cpp",
    "validate_constants.cpp",
    "validate_conversion.cpp",
    "validate_debug.cpp",
    "validate_decorations.cpp",
    "validate_derivatives.cpp",
    "validate_execution_limitations.cpp",
    "validate_extensions.cpp",
    "validate_function.cpp",
    "validate_graph.cpp",
    "validate_id.cpp",
    "validate_image.cpp",
    "validate_instruction.cpp",
    "validate_interfaces.cpp",
    "validate_layout.cpp",
    "validate_literals.cpp",
    "validate_logicals.cpp",
    "validate_logical_pointers.cpp",
    "validate_memory.cpp",
    "validate_memory_semantics.cpp",
    "validate_mesh_shading.cpp",
    "validate_misc.cpp",
    "validate_mode_setting.cpp",
    "validate_non_uniform.cpp",
    "validate_primitives.cpp",
    "validate_ray_query.cpp",
    "validate_ray_tracing.cpp",
    "validate_ray_tracing_reorder.cpp",
    "validate_scopes.cpp",
    "validate_small_type_uses.cpp",
    "validate_tensor.cpp",
    "validate_tensor_layout.cpp",
    "validate_type.cpp",
    "validate_invalid_type.cpp",
    "validation_state.cpp",
};

const spvtools_opt_sources: []const []const u8 = &.{
    "aggressive_dead_code_elim_pass.cpp",
    "amd_ext_to_khr.cpp",
    "analyze_live_input_pass.cpp",
    "basic_block.cpp",
    "block_merge_pass.cpp",
    "block_merge_util.cpp",
    "build_module.cpp",
    "ccp_pass.cpp",
    "cfg.cpp",
    "cfg_cleanup_pass.cpp",
    "code_sink.cpp",
    "combine_access_chains.cpp",
    "compact_ids_pass.cpp",
    "composite.cpp",
    "const_folding_rules.cpp",
    "constants.cpp",
    "control_dependence.cpp",
    "convert_to_half_pass.cpp",
    "convert_to_sampled_image_pass.cpp",
    "copy_prop_arrays.cpp",
    "dataflow.cpp",
    "dead_branch_elim_pass.cpp",
    "dead_insert_elim_pass.cpp",
    "dead_variable_elimination.cpp",
    "debug_info_manager.cpp",
    "decoration_manager.cpp",
    "def_use_manager.cpp",
    "desc_sroa.cpp",
    "desc_sroa_util.cpp",
    "dominator_analysis.cpp",
    "dominator_tree.cpp",
    "eliminate_dead_constant_pass.cpp",
    "eliminate_dead_functions_pass.cpp",
    "eliminate_dead_functions_util.cpp",
    "eliminate_dead_io_components_pass.cpp",
    "eliminate_dead_members_pass.cpp",
    "eliminate_dead_output_stores_pass.cpp",
    "feature_manager.cpp",
    "fix_func_call_arguments.cpp",
    "fix_storage_class.cpp",
    "flatten_decoration_pass.cpp",
    "fold.cpp",
    "fold_spec_constant_op_and_composite_pass.cpp",
    "folding_rules.cpp",
    "freeze_spec_constant_value_pass.cpp",
    "function.cpp",
    "graph.cpp",
    "graphics_robust_access_pass.cpp",
    "if_conversion.cpp",
    "inline_exhaustive_pass.cpp",
    "inline_opaque_pass.cpp",
    "inline_pass.cpp",
    "instruction.cpp",
    "instruction_list.cpp",
    "interface_var_sroa.cpp",
    "interp_fixup_pass.cpp",
    "invocation_interlock_placement_pass.cpp",
    "ir_context.cpp",
    "ir_loader.cpp",
    "licm_pass.cpp",
    "liveness.cpp",
    "local_access_chain_convert_pass.cpp",
    "local_redundancy_elimination.cpp",
    "local_single_block_elim_pass.cpp",
    "local_single_store_elim_pass.cpp",
    "loop_dependence.cpp",
    "loop_dependence_helpers.cpp",
    "loop_descriptor.cpp",
    "loop_fission.cpp",
    "loop_fusion.cpp",
    "loop_fusion_pass.cpp",
    "loop_peeling.cpp",
    "loop_unroller.cpp",
    "loop_unswitch_pass.cpp",
    "loop_utils.cpp",
    "mem_pass.cpp",
    "merge_return_pass.cpp",
    "modify_maximal_reconvergence.cpp",
    "module.cpp",
    "opextinst_forward_ref_fixup_pass.cpp",
    "optimizer.cpp",
    "pass.cpp",
    "pass_manager.cpp",
    "private_to_local_pass.cpp",
    "propagator.cpp",
    "reduce_load_size.cpp",
    "redundancy_elimination.cpp",
    "register_pressure.cpp",
    "relax_float_ops_pass.cpp",
    "remove_dontinline_pass.cpp",
    "remove_duplicates_pass.cpp",
    "remove_unused_interface_variables_pass.cpp",
    "canonicalize_ids_pass.cpp",
    "replace_desc_array_access_using_var_index.cpp",
    "replace_invalid_opc.cpp",
    "resolve_binding_conflicts_pass.cpp",
    "scalar_analysis.cpp",
    "scalar_analysis_simplification.cpp",
    "scalar_replacement_pass.cpp",
    "set_spec_constant_default_value_pass.cpp",
    "simplification_pass.cpp",
    "split_combined_image_sampler_pass.cpp",
    "spread_volatile_semantics.cpp",
    "ssa_rewrite_pass.cpp",
    "strength_reduction_pass.cpp",
    "strip_debug_info_pass.cpp",
    "strip_nonsemantic_info_pass.cpp",
    "struct_packing_pass.cpp",
    "struct_cfg_analysis.cpp",
    "switch_descriptorset_pass.cpp",
    "trim_capabilities_pass.cpp",
    "type_manager.cpp",
    "types.cpp",
    "unify_const_pass.cpp",
    "upgrade_memory_model.cpp",
    "value_number_table.cpp",
    "vector_dce.cpp",
    "workaround1209.cpp",
    "wrap_opkill.cpp",
};

const spvtools_link_sources: []const []const u8 = &.{
    "linker.cpp",
};

const spvtools_reduce_sources: []const []const u8 = &.{
    "change_operand_reduction_opportunity.cpp",
    "change_operand_to_undef_reduction_opportunity.cpp",
    "conditional_branch_to_simple_conditional_branch_opportunity_finder.cpp",
    "conditional_branch_to_simple_conditional_branch_reduction_opportunity.cpp",
    "merge_blocks_reduction_opportunity.cpp",
    "merge_blocks_reduction_opportunity_finder.cpp",
    "operand_to_const_reduction_opportunity_finder.cpp",
    "operand_to_dominating_id_reduction_opportunity_finder.cpp",
    "operand_to_undef_reduction_opportunity_finder.cpp",
    "reducer.cpp",
    "reduction_opportunity.cpp",
    "reduction_opportunity_finder.cpp",
    "reduction_pass.cpp",
    "reduction_util.cpp",
    "remove_block_reduction_opportunity.cpp",
    "remove_block_reduction_opportunity_finder.cpp",
    "remove_function_reduction_opportunity.cpp",
    "remove_function_reduction_opportunity_finder.cpp",
    "remove_instruction_reduction_opportunity.cpp",
    "remove_selection_reduction_opportunity.cpp",
    "remove_selection_reduction_opportunity_finder.cpp",
    "remove_struct_member_reduction_opportunity.cpp",
    "remove_unused_instruction_reduction_opportunity_finder.cpp",
    "remove_unused_struct_member_reduction_opportunity_finder.cpp",
    "simple_conditional_branch_to_branch_opportunity_finder.cpp",
    "simple_conditional_branch_to_branch_reduction_opportunity.cpp",
    "structured_construct_to_block_reduction_opportunity.cpp",
    "structured_construct_to_block_reduction_opportunity_finder.cpp",
    "structured_loop_to_selection_reduction_opportunity.cpp",
    "structured_loop_to_selection_reduction_opportunity_finder.cpp",
};

const Version = struct {
    step: std.Build.Step,
    version: std.SemanticVersion,

    pub fn init(b: *std.Build) !*Version {
        var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
        defer tree.deinit(b.allocator);

        const version = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
        const semantic_version = try std.SemanticVersion.parse(version[1 .. version.len - 1]);

        const self = b.allocator.create(Version) catch @panic("OOM");
        self.step = std.Build.Step.init(.{
            .name = "version",
            .id = .custom,
            .owner = b,
            .makeFn = Version.make,
        });
        self.version = semantic_version;
        if (self.version.pre) |pre| {
            if (std.mem.eql(u8, pre, "dev")) {
                const hash = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });
                const trimmed = std.mem.trim(u8, hash, "\r\n ");
                self.version.pre = b.allocator.dupe(u8, trimmed) catch @panic("OOM");
            }
        }
        return self;
    }

    pub fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *Version = @fieldParentPtr("step", step);
        const file: std.fs.File = .stdout();
        var writer = file.writer(&.{});
        try writer.interface.print("{f}\n", .{self.version});
    }
};
