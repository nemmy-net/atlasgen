const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftmm.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("stb_rect_pack.h");
});

const GlyphData = struct {
    rect_index: usize = std.math.maxInt(usize),
    glyph_index: c.FT_UInt,
    width: c.FT_UInt,
    height: c.FT_UInt,
    left_bearing: c.FT_Int,
    top_bearing: c.FT_Int,
    advance: c.FT_Pos,
};

const Range = struct { first: u32, last: u32 };
const AxisSetting = struct { name: []const u8, value: c.FT_Fixed, used: bool = false };

fn printHelp() void {
    std.debug.print(
        \\atlasgen --font <file> --out <folder>
        \\Writes atlas.ga (row-major GA8 pixels) and map.json. Encode atlas.ga in the browser if PNG is needed.
        \\Optional:
        \\  --size <pixels>       Set font height. Default is 16.
        \\  --mono                Render 1-bit black and white with no anti-aliasing.
        \\  --range <int> <int>   Render this inclusive codepoint range. May be repeated.
        \\  --ascii               Same as --range 32 126.
        \\  --add-height <pixels> Adjust the vertical distance between lines.
        \\  --axis <name> <float> Set a variable font axis.
        \\  --embolden            Stretch glyph outlines to be wider.
        \\  --help                Show this message.
        \\
    , .{});
}

fn ftCheck(err: c.FT_Error, operation: []const u8) !void {
    if (err != 0) {
        std.debug.print("{s}: FreeType error {d}\n", .{ operation, err });
        return error.FreeType;
    }
}

fn appendRange(ranges: *std.ArrayList(Range), allocator: std.mem.Allocator, first: u32, last: u32) !void {
    if (first >= last) {
        std.debug.print("Invalid range. Right value must be larger than left value.\n", .{});
        return error.InvalidArguments;
    }
    try ranges.append(allocator, .{ .first = first, .last = last });
}

fn renderGlyph(face: c.FT_Face, glyph_index: c.FT_UInt, mono: bool, embolden: bool) !void {
    try ftCheck(c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_DEFAULT), "loading glyph");
    const slot = face.*.glyph;
    if (embolden and slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
        try ftCheck(c.FT_Outline_EmboldenXY(&slot.*.outline, 1 << 6, 0), "emboldening glyph");
    }
    if (slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) {
        try ftCheck(c.FT_Render_Glyph(slot, if (mono) c.FT_RENDER_MODE_MONO else c.FT_RENDER_MODE_LIGHT), "rendering glyph");
    }
}

fn writeNumber(io: std.Io, file: std.Io.File, number: anytype) !void {
    var buffer: [64]u8 = undefined;
    try file.writeStreamingAll(io, try std.fmt.bufPrint(&buffer, "{d}", .{number}));
}

fn copyGlyphBitmap(atlas: []u8, atlas_width: usize, rect: c.stbrp_rect, bitmap: c.FT_Bitmap) !void {
    const pixel_mode = bitmap.pixel_mode;
    if (pixel_mode != c.FT_PIXEL_MODE_GRAY and pixel_mode != c.FT_PIXEL_MODE_MONO) {
        std.debug.print("Unsupported FT_Pixel_Mode {d}\n", .{pixel_mode});
        return error.UnsupportedPixelMode;
    }

    const source_pitch: isize = @intCast(bitmap.pitch);
    const absolute_pitch: usize = @intCast(if (source_pitch < 0) -source_pitch else source_pitch);
    const rows: usize = @intCast(bitmap.rows);
    const width: usize = @intCast(bitmap.width);
    const destination_x: usize = @intCast(rect.x);
    const destination_y: usize = @intCast(rect.y);
    const source = bitmap.buffer;

    for (0..rows) |y| {
        const source_row = if (source_pitch < 0) rows - 1 - y else y;
        for (0..width) |x| {
            const source_byte = source[source_row * absolute_pitch + if (pixel_mode == c.FT_PIXEL_MODE_MONO) x / 8 else x];
            const alpha: u8 = if (pixel_mode == c.FT_PIXEL_MODE_MONO)
                @intCast(((source_byte >> @as(u3, @intCast(7 - (x % 8)))) & 1) * 255)
            else
                source_byte;
            const destination = ((destination_y + y) * atlas_width + destination_x + x) * 2;
            atlas[destination + 1] = alpha;
        }
    }
}

pub fn main(process: std.process.Init) !void {
    const allocator = process.gpa;

    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);
    var axes: std.ArrayList(AxisSetting) = .empty;
    defer axes.deinit(allocator);

    var font_path: ?[:0]const u8 = null;
    var output_path: ?[:0]const u8 = null;
    var desired_size: c.FT_UInt = 16;
    var add_height: i32 = 0;
    var mono = false;
    var embolden = false;
    var flag_count: usize = 0;

    var arguments = try std.process.Args.Iterator.initAllocator(process.minimal.args, allocator);
    defer arguments.deinit();
    _ = arguments.next();
    while (arguments.next()) |argument| {
        flag_count += 1;
        if (std.mem.eql(u8, argument, "--font")) {
            font_path = arguments.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--out")) {
            output_path = arguments.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--size")) {
            const value = arguments.next() orelse return error.InvalidArguments;
            desired_size = std.fmt.parseInt(c.FT_UInt, value, 10) catch return error.InvalidArguments;
            if (desired_size == 0) return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--range")) {
            const first_text = arguments.next() orelse return error.InvalidArguments;
            const last_text = arguments.next() orelse return error.InvalidArguments;
            const first = std.fmt.parseInt(u32, first_text, 10) catch return error.InvalidArguments;
            const last = std.fmt.parseInt(u32, last_text, 10) catch return error.InvalidArguments;
            try appendRange(&ranges, allocator, first, last);
        } else if (std.mem.eql(u8, argument, "--ascii")) {
            try appendRange(&ranges, allocator, 32, 126);
        } else if (std.mem.eql(u8, argument, "--axis")) {
            const name = arguments.next() orelse return error.InvalidArguments;
            const value_text = arguments.next() orelse return error.InvalidArguments;
            const value = std.fmt.parseFloat(f64, value_text) catch return error.InvalidArguments;
            const fixed: c.FT_Fixed = @intFromFloat(value * 65536.0);
            var duplicate = false;
            for (axes.items) |axis| if (std.mem.eql(u8, axis.name, name)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try axes.append(allocator, .{ .name = name, .value = fixed });
        } else if (std.mem.eql(u8, argument, "--mono")) {
            mono = true;
        } else if (std.mem.eql(u8, argument, "--add-height")) {
            const value = arguments.next() orelse return error.InvalidArguments;
            add_height = std.fmt.parseInt(i32, value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, argument, "--embolden")) {
            embolden = true;
        } else if (std.mem.eql(u8, argument, "--help")) {
            printHelp();
            return;
        } else {
            std.debug.print("Unknown flag: {s}\n", .{argument});
            return error.InvalidArguments;
        }
    }

    if (flag_count == 0) {
        printHelp();
        return;
    }
    const font = font_path orelse {
        std.debug.print("--font and --out must be set\n", .{});
        return error.InvalidArguments;
    };
    const output = output_path orelse {
        std.debug.print("--font and --out must be set\n", .{});
        return error.InvalidArguments;
    };

    var library: c.FT_Library = undefined;
    try ftCheck(c.FT_Init_FreeType(&library), "initializing FreeType");
    defer _ = c.FT_Done_FreeType(library);

    var face: c.FT_Face = undefined;
    try ftCheck(c.FT_New_Face(library, font.ptr, 0, &face), "opening font");
    defer _ = c.FT_Done_Face(face);
    try ftCheck(c.FT_Set_Pixel_Sizes(face, 0, desired_size), "setting pixel size");

    if (axes.items.len != 0) {
        var master: [*c]c.FT_MM_Var = null;
        try ftCheck(c.FT_Get_MM_Var(face, &master), "reading font axes");
        defer _ = c.FT_Done_MM_Var(library, master);

        var coordinates: std.ArrayList(c.FT_Fixed) = .empty;
        defer coordinates.deinit(allocator);
        for (0..master.*.num_axis) |index| {
            const axis = master.*.axis[index];
            const axis_name = std.mem.span(axis.name);
            var coordinate = axis.def;
            for (axes.items) |*setting| {
                if (std.mem.eql(u8, setting.name, axis_name)) {
                    coordinate = setting.value;
                    setting.used = true;
                    break;
                }
            }
            if (coordinate < axis.minimum or coordinate > axis.maximum) {
                std.debug.print("Axis {s} must be within the font's supported range\n", .{axis_name});
                return error.InvalidArguments;
            }
            try coordinates.append(allocator, coordinate);
        }
        for (axes.items) |setting| {
            if (!setting.used) {
                std.debug.print("The provided axis does not exist in this font: {s}\n", .{setting.name});
                return error.InvalidArguments;
            }
        }
        try ftCheck(c.FT_Set_Var_Design_Coordinates(face, @intCast(coordinates.items.len), coordinates.items.ptr), "setting font axes");
    }

    if (ranges.items.len == 0) {
        var glyph_index: c.FT_UInt = 0;
        var first = c.FT_Get_First_Char(face, &glyph_index);
        if (glyph_index == 0) {
            std.debug.print("Font has no charmap\n", .{});
            return error.InvalidFont;
        }
        var last = first;
        while (true) {
            const next = c.FT_Get_Next_Char(face, last, &glyph_index);
            if (next == 0) break;
            if (next != last + 1) {
                try ranges.append(allocator, .{ .first = @intCast(first), .last = @intCast(last) });
                first = next;
            }
            last = next;
        }
        try ranges.append(allocator, .{ .first = @intCast(first), .last = @intCast(last) });
    }

    var glyphs: std.ArrayList(GlyphData) = .empty;
    defer glyphs.deinit(allocator);
    var glyph_indices = std.AutoHashMap(c.FT_UInt, usize).init(allocator);
    defer glyph_indices.deinit();
    var rectangles: std.ArrayList(c.stbrp_rect) = .empty;
    defer rectangles.deinit(allocator);

    var total_width: u64 = 0;
    var total_height: u64 = 0;
    for (ranges.items) |range| {
        var codepoint = range.first;
        while (true) {
            const glyph_index = c.FT_Get_Char_Index(face, codepoint);
            if (!glyph_indices.contains(glyph_index)) {
                try renderGlyph(face, glyph_index, mono, embolden);
                const slot = face.*.glyph;
                const bitmap = slot.*.bitmap;
                var glyph = GlyphData{
                    .glyph_index = glyph_index,
                    .width = bitmap.width,
                    .height = bitmap.rows,
                    .left_bearing = slot.*.bitmap_left,
                    .top_bearing = slot.*.bitmap_top,
                    .advance = slot.*.advance.x,
                };
                if (bitmap.width != 0 and bitmap.rows != 0) {
                    total_width += bitmap.width;
                    total_height += bitmap.rows;
                    glyph.rect_index = rectangles.items.len;
                    try rectangles.append(allocator, .{ .id = 0, .w = @intCast(bitmap.width + 2), .h = @intCast(bitmap.rows + 2), .x = 0, .y = 0, .was_packed = 0 });
                }
                try glyph_indices.put(glyph_index, glyphs.items.len);
                try glyphs.append(allocator, glyph);
            }
            if (codepoint == range.last) break;
            codepoint += 1;
        }
    }

    var atlas_width: usize = 1;
    var atlas_height: usize = 1;
    if (rectangles.items.len != 0) {
        atlas_width = @max(1, @as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(total_width))))));
        atlas_height = @max(1, @as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(total_height))))));
        var are_rectangles_packed = false;
        while (!are_rectangles_packed) {
            var context: c.stbrp_context = undefined;
            const node_count = try std.math.mul(usize, atlas_width, 2);
            const nodes = try allocator.alloc(c.stbrp_node, node_count);
            defer allocator.free(nodes);
            c.stbrp_init_target(&context, @intCast(atlas_width), @intCast(atlas_height), nodes.ptr, @intCast(nodes.len));
            are_rectangles_packed = c.stbrp_pack_rects(&context, rectangles.items.ptr, @intCast(rectangles.items.len)) != 0;
            if (!are_rectangles_packed) {
                atlas_width = try std.math.add(usize, atlas_width, @max(1, atlas_width / 5));
                atlas_height = try std.math.add(usize, atlas_height, @max(1, atlas_height / 5));
            }
        }
        for (rectangles.items) |rectangle| {
            atlas_width = @max(atlas_width, @as(usize, @intCast(rectangle.x + rectangle.w)));
            atlas_height = @max(atlas_height, @as(usize, @intCast(rectangle.y + rectangle.h)));
        }
    }

    const atlas_size = try std.math.mul(usize, try std.math.mul(usize, atlas_width, atlas_height), 2);
    var atlas = try allocator.alloc(u8, atlas_size);
    defer allocator.free(atlas);
    for (0..atlas_width * atlas_height) |index| {
        atlas[index * 2] = 255;
        atlas[index * 2 + 1] = 0;
    }

    for (glyphs.items) |glyph| {
        if (glyph.rect_index == std.math.maxInt(usize)) continue;
        try renderGlyph(face, glyph.glyph_index, mono, embolden);
        var rectangle = &rectangles.items[glyph.rect_index];
        rectangle.x += 1;
        rectangle.y += 1;
        rectangle.w -= 2;
        rectangle.h -= 2;
        try copyGlyphBitmap(atlas, atlas_width, rectangle.*, face.*.glyph.*.bitmap);
    }

    const output_dir = try std.Io.Dir.cwd().createDirPathOpen(process.io, output, .{});
    defer output_dir.close(process.io);

    const atlas_file = try output_dir.createFile(process.io, "atlas.ga", .{});
    defer atlas_file.close(process.io);
    try atlas_file.writeStreamingAll(process.io, atlas);

    const map_file = try output_dir.createFile(process.io, "map.json", .{});
    defer map_file.close(process.io);
    try map_file.writeStreamingAll(process.io, "{\"version\":1,\"atlas\":{\"file\":\"atlas.ga\",\"format\":\"ga8\",\"width\":");
    try writeNumber(process.io, map_file, atlas_width);
    try map_file.writeStreamingAll(process.io, ",\"height\":");
    try writeNumber(process.io, map_file, atlas_height);
    try map_file.writeStreamingAll(process.io, "},\"glyphs\":[");

    var previous_glyph = GlyphData{ .glyph_index = 0, .width = 0, .height = 0, .left_bearing = 0, .top_bearing = 0, .advance = 0 };
    var previous_x: i64 = 0;
    var previous_y: i64 = 0;
    for (glyphs.items, 0..) |glyph, index| {
        if (index != 0) try map_file.writeStreamingAll(process.io, ",");
        const rectangle = if (glyph.rect_index == std.math.maxInt(usize)) null else rectangles.items[glyph.rect_index];
        const x: i64 = if (rectangle) |value| value.x else 0;
        const y: i64 = if (rectangle) |value| value.y else 0;
        const values = [_]i64{
            @as(i64, glyph.width) - @as(i64, previous_glyph.width),
            @as(i64, glyph.height) - @as(i64, previous_glyph.height),
            @as(i64, glyph.left_bearing) - @as(i64, previous_glyph.left_bearing),
            @as(i64, glyph.top_bearing) - @as(i64, previous_glyph.top_bearing),
            (@as(i64, glyph.advance) - @as(i64, previous_glyph.advance)) >> 6,
            x - previous_x,
            y - previous_y,
        };
        for (values, 0..) |value, value_index| {
            if (value_index != 0) try map_file.writeStreamingAll(process.io, ",");
            try writeNumber(process.io, map_file, value);
        }
        previous_glyph = glyph;
        previous_x = x;
        previous_y = y;
    }

    try map_file.writeStreamingAll(process.io, "],\"codepoints\":[");
    var previous_codepoint: i64 = 0;
    var previous_glyph_id: i64 = 0;
    var first_codepoint = true;
    for (ranges.items) |range| {
        var codepoint = range.first;
        while (true) {
            const glyph_index = c.FT_Get_Char_Index(face, codepoint);
            if (glyph_index != 0) {
                const glyph_id: i64 = @intCast(glyph_indices.get(glyph_index).?);
                if (!first_codepoint) try map_file.writeStreamingAll(process.io, ",");
                try writeNumber(process.io, map_file, @as(i64, codepoint) - previous_codepoint);
                try map_file.writeStreamingAll(process.io, ",");
                try writeNumber(process.io, map_file, glyph_id - previous_glyph_id);
                previous_codepoint = codepoint;
                previous_glyph_id = glyph_id;
                first_codepoint = false;
            }
            if (codepoint == range.last) break;
            codepoint += 1;
        }
    }

    try map_file.writeStreamingAll(process.io, "],\"metrics\":{\"ascender\":");
    try writeNumber(process.io, map_file, face.*.size.*.metrics.ascender >> 6);
    try map_file.writeStreamingAll(process.io, ",\"descender\":");
    try writeNumber(process.io, map_file, face.*.size.*.metrics.descender >> 6);
    try map_file.writeStreamingAll(process.io, ",\"height\":");
    try writeNumber(process.io, map_file, (face.*.size.*.metrics.height >> 6) + add_height);
    try map_file.writeStreamingAll(process.io, "}}");
}
