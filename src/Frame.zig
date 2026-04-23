const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const lz4u = @import("lz4u.zig");

pub const Decompress = @import("frame/Decompress.zig");
pub const Compress = @import("frame/Compress.zig");

pub const BlockMaxSize = enum(u3) {
    @"64KB" = 4,
    @"256KB" = 5,
    @"1MB" = 6,
    @"4MB" = 7,

    pub fn toBytes(self: BlockMaxSize) u32 {
        return switch (self) {
            .@"64KB" => 64 * 1024,
            .@"256KB" => 256 * 1024,
            .@"1MB" => 1 * 1024 * 1024,
            .@"4MB" => 4 * 1024 * 1024,
        };
    }
};

pub const Header = struct {
    pub const MAGIC: u32 = 0x184d2204;

    pub const Flg = packed struct(u8) {
        dict_id: bool,
        _: u1 = 0,
        content_chksum: bool,
        content_size: bool,
        block_chksum: bool,
        block_indep: bool,
        version: u2 = 1,
    };

    pub const Bd = packed struct(u8) {
        _: u4 = 0,
        block_max_size: BlockMaxSize,
        _2: u1 = 0,
    };

    flg: Flg,
    bd: Bd,
    content_size: ?u64,
    dict_id: ?u32,
};

const testing = std.testing;

//
// tests based off Zig's zstd decompressor
//
fn testDecompress(gpa: mem.Allocator, compressed: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, Decompress.queryOutCapacity());
    defer out.deinit();

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, &.{}, .{});
    _ = try lz4_stream.reader.streamRemaining(&out.writer);

    return out.toOwnedSlice();
}

fn testDecompressIndirect(gpa: mem.Allocator, compressed: []const u8) ![]u8 {
    const indirect_buf = try gpa.alloc(u8, lz4u.min_indirect_buffer_len);
    defer gpa.free(indirect_buf);

    var out: Io.Writer.Allocating = try .initCapacity(gpa, Decompress.queryOutCapacity());
    defer out.deinit();

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, indirect_buf, .{});
    _ = try lz4_stream.reader.streamRemaining(&out.writer);

    return out.toOwnedSlice();
}

/// Create a `Decompress` from `compressed` and immediately discard all output. Returns the number
/// of discarded bytes.
fn testDiscard(gpa: mem.Allocator, compressed: []const u8) !usize {
    const buf = try gpa.alloc(u8, lz4u.min_indirect_buffer_len);
    defer gpa.free(buf);

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, buf, .{});
    return try lz4_stream.reader.discardRemaining();
}

fn testExpectDecompress(uncompressed: []const u8, compressed: []const u8) !void {
    const gpa = testing.allocator;
    const result = try testDecompress(gpa, compressed);
    defer gpa.free(result);
    try testing.expectEqualSlices(u8, uncompressed, result);
}

fn testExpectDecompressIndirect(uncompressed: []const u8, compressed: []const u8) !void {
    const gpa = testing.allocator;
    const result = try testDecompressIndirect(gpa, compressed);
    defer gpa.free(result);
    try testing.expectEqualSlices(u8, uncompressed, result);
}

fn testExpectDecompressError(err: anyerror, compressed: []const u8) !void {
    const gpa = testing.allocator;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, &.{}, .{ .verify_checksum = true });
    try testing.expectError(
        error.ReadFailed,
        lz4_stream.reader.streamRemaining(&out.writer),
    );
    try testing.expectError(err, lz4_stream.err orelse {});
}

test "small file decompression" {
    const uncompressed = @embedFile("testdata/one_word.txt");
    const compressed = @embedFile("testdata/one_word.txt.lz4");

    try testExpectDecompress(uncompressed, compressed);
    try testing.expectEqual(uncompressed.len, testDiscard(testing.allocator, compressed));

    try testExpectDecompressIndirect(uncompressed, compressed);
}

test "large file decompression" {
    const uncompressed = @embedFile("testdata/plane_scene.txt");
    const compressed_dep = @embedFile("testdata/plane_scene_blockdep.txt.lz4");
    const compressed_indep = @embedFile("testdata/plane_scene_blockindep.txt.lz4");

    try testExpectDecompress(uncompressed, compressed_dep);
    try testExpectDecompress(uncompressed, compressed_indep);

    try testing.expectEqual(uncompressed.len, testDiscard(testing.allocator, compressed_dep));
    try testing.expectEqual(uncompressed.len, testDiscard(testing.allocator, compressed_indep));

    try testExpectDecompressIndirect(uncompressed, compressed_dep);
    try testExpectDecompressIndirect(uncompressed, compressed_indep);
}

test "4MB block dependant file decompression" {
    const uncompressed = @embedFile("testdata/memory_archive.tar");
    const compressed = @embedFile("testdata/memory_archive.tar.lz4");

    try testExpectDecompress(uncompressed, compressed);
    try testExpectDecompressIndirect(uncompressed, compressed);
}

test "partial magic number" {
    const input_raw =
        "\x04\x22\x4d"; // 3 bytes of the 4-byte lz4 frame magic number
    try testExpectDecompressError(error.InvalidMagic, input_raw);
}

fn testCompress(gpa: mem.Allocator, uncompressed: []const u8, options: Compress.Options) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, Compress.queryOutCapacity(options));
    defer out.deinit();

    const window_buf = try gpa.alloc(u8, lz4u.max_window_len);
    defer gpa.free(window_buf);

    var compressor: Compress = try .init(&out.writer, window_buf, options);

    try compressor.writer.writeAll(uncompressed);
    try compressor.finish();

    return out.toOwnedSlice();
}

fn testExpectCompress(uncompressed: []const u8, compressed: []const u8, options: Compress.Options) !void {
    const gpa = testing.allocator;
    const result = try testCompress(gpa, uncompressed, options);
    defer gpa.free(result);
    try testing.expectEqualSlices(u8, compressed, result);
}

test "small file compression" {
    const uncompressed = @embedFile("testdata/one_word.txt");
    const compressed = @embedFile("testdata/one_word.txt.lz4");

    try testExpectCompress(uncompressed, compressed, .{
        .max_block_size = .@"64KB",
        .should_checksum_frame = true,
        .should_checksum_block = false,
        .independent_blocks = true,
    });
}

test "text file compression" {
    const uncompressed = @embedFile("testdata/plane_scene.txt");
    const compressed_dep = @embedFile("testdata/plane_scene_blockdep.txt.lz4");
    const compressed_indep = @embedFile("testdata/plane_scene_blockindep.txt.lz4");

    try testExpectCompress(uncompressed, compressed_indep, .{
        .max_block_size = .@"256KB",
        .should_checksum_frame = true,
        .should_checksum_block = false,
        .independent_blocks = true,
    });
    try testExpectCompress(uncompressed, compressed_dep, .{
        .max_block_size = .@"64KB",
        .should_checksum_frame = true,
        .should_checksum_block = false,
        .independent_blocks = false,
    });
}

test "large file compression" {
    const uncompressed = @embedFile("testdata/buncha_floats.bin");
    const compressed_indep = @embedFile("testdata/buncha_floats.bin.lz4");

    try testExpectCompress(uncompressed, compressed_indep, .{
        .max_block_size = .@"4MB",
        .should_checksum_frame = true,
        .should_checksum_block = false,
        .independent_blocks = true,
    });
}

test "4MB dependent archive file compression" {
    const uncompressed = @embedFile("testdata/memory_archive.tar");
    const compressed_dep = @embedFile("testdata/memory_archive.tar.lz4");

    try testExpectCompress(uncompressed, compressed_dep, .{
        .max_block_size = .@"4MB",
        .should_checksum_frame = true,
        .should_checksum_block = true,
        .independent_blocks = false,
    });
}
