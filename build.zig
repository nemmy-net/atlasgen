const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "atlasgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (target.result.os.tag == .wasi) {
        exe.root_module.addIncludePath(b.path("src/wasi"));
    }
    exe.root_module.addIncludePath(b.path("deps/freetype/include"));
    exe.root_module.addIncludePath(b.path("deps/stb"));
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/stb_rect_pack.c",
            "deps/freetype/src/autofit/autofit.c",
            "deps/freetype/src/base/ftbase.c",
            "deps/freetype/src/base/ftbbox.c",
            "deps/freetype/src/base/ftbdf.c",
            "deps/freetype/src/base/ftbitmap.c",
            "deps/freetype/src/base/ftcid.c",
            "deps/freetype/src/base/ftfstype.c",
            "deps/freetype/src/base/ftgasp.c",
            "deps/freetype/src/base/ftglyph.c",
            "deps/freetype/src/base/ftgxval.c",
            "deps/freetype/src/base/ftinit.c",
            "deps/freetype/src/base/ftmm.c",
            "deps/freetype/src/base/ftotval.c",
            "deps/freetype/src/base/ftpatent.c",
            "deps/freetype/src/base/ftpfr.c",
            "deps/freetype/src/base/ftstroke.c",
            "deps/freetype/src/base/ftsynth.c",
            "deps/freetype/src/base/fttype1.c",
            "deps/freetype/src/base/ftwinfnt.c",
            "deps/freetype/src/base/ftsystem.c",
            "deps/freetype/src/base/ftdebug.c",
            "deps/freetype/src/bdf/bdf.c",
            "deps/freetype/src/bzip2/ftbzip2.c",
            "deps/freetype/src/cff/cff.c",
            "deps/freetype/src/cid/type1cid.c",
            "deps/freetype/src/gzip/ftgzip.c",
            "deps/freetype/src/lzw/ftlzw.c",
            "deps/freetype/src/pcf/pcf.c",
            "deps/freetype/src/pfr/pfr.c",
            "deps/freetype/src/psaux/psaux.c",
            "deps/freetype/src/pshinter/pshinter.c",
            "deps/freetype/src/psnames/psnames.c",
            "deps/freetype/src/raster/raster.c",
            "deps/freetype/src/sdf/sdf.c",
            "deps/freetype/src/sfnt/sfnt.c",
            "deps/freetype/src/smooth/smooth.c",
            "deps/freetype/src/svg/svg.c",
            "deps/freetype/src/truetype/truetype.c",
            "deps/freetype/src/type1/type1.c",
            "deps/freetype/src/type42/type42.c",
            "deps/freetype/src/winfonts/winfnt.c",
        },
        .flags = &.{ "-std=c11", "-DFT2_BUILD_LIBRARY" },
    });
    exe.root_module.link_libc = true;

    b.installArtifact(exe);
}
