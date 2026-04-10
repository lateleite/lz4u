const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const lz4u = @import("lz4u.zig");

pub const Decompress = @import("raw/Decompress.zig");
pub const Compress = @import("raw/Compress.zig");

const testing = std.testing;

fn testDecompress(gpa: mem.Allocator, compressed: []const u8, options: Decompress.Options) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, &.{}, options);
    _ = try lz4_stream.reader.streamRemaining(&out.writer);

    return out.toOwnedSlice();
}

fn testDecompressIndirect(gpa: mem.Allocator, compressed: []const u8, options: Decompress.Options) ![]u8 {
    const indirect_buf = try gpa.alloc(u8, Decompress.queryIndirectCapacity(options));
    defer gpa.free(indirect_buf);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, indirect_buf, options);
    _ = try lz4_stream.reader.streamRemaining(&out.writer);

    return out.toOwnedSlice();
}

fn testDiscard(gpa: mem.Allocator, compressed: []const u8, options: Decompress.Options) !usize {
    const buf = try gpa.alloc(u8, Decompress.queryIndirectCapacity(options));
    defer gpa.free(buf);

    var in: Io.Reader = .fixed(compressed);
    var lz4_stream: Decompress = .init(&in, buf, options);
    return try lz4_stream.reader.discardRemaining();
}

fn testExpectDecompress(uncompressed: []const u8, compressed: []const u8, options: Decompress.Options) !void {
    const gpa = testing.allocator;
    const result = try testDecompress(gpa, compressed, options);
    defer gpa.free(result);
    try testing.expectEqualSlices(u8, uncompressed, result);
}

fn testExpectDecompressIndirect(uncompressed: []const u8, compressed: []const u8, options: Decompress.Options) !void {
    const gpa = testing.allocator;
    const result = try testDecompressIndirect(gpa, compressed, options);
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

test "raw small file decompression" {
    const uncompressed = @embedFile("testdata/one_word.txt");
    const compressed = @embedFile("testdata/one_word.raw.lz4");

    try testExpectDecompress(uncompressed, compressed, .{
        .max_block_size = 64 * 1024,
    });
    try testing.expectEqual(uncompressed.len, testDiscard(testing.allocator, compressed, .{
        .max_block_size = 64 * 1024,
    }));

    try testExpectDecompressIndirect(uncompressed, compressed, .{
        .max_block_size = 64 * 1024,
    });
}

test "raw large file decompression" {
    const uncompressed = @embedFile("testdata/plane_scene.txt");
    const compressed = @embedFile("testdata/plane_scene.raw.lz4");

    try testExpectDecompress(uncompressed, compressed, .{
        .max_block_size = 64 * 1024,
    });
    try testing.expectEqual(uncompressed.len, testDiscard(testing.allocator, compressed, .{
        .max_block_size = 64 * 1024,
    }));
    try testExpectDecompressIndirect(uncompressed, compressed, .{
        .max_block_size = 64 * 1024,
    });
}

fn testCompress(gpa: mem.Allocator, uncompressed: []const u8, options: Compress.Options) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const window_buf = try gpa.alloc(u8, lz4u.max_window_len);
    defer gpa.free(window_buf);

    var compressor: Compress = .init(&out.writer, window_buf, options);

    try compressor.writer.writeAll(uncompressed);
    try compressor.writer.flush();

    return out.toOwnedSlice();
}

fn testExpectCompress(uncompressed: []const u8, compressed: []const u8, options: Compress.Options) !void {
    const gpa = testing.allocator;
    const result = try testCompress(gpa, uncompressed, options);
    defer gpa.free(result);
    try testing.expectEqualSlices(u8, compressed, result);
}

test "raw small data compression" {
    const uncompressed = @embedFile("testdata/one_word.txt");
    const compressed = @embedFile("testdata/one_word.raw.lz4");

    try testExpectCompress(uncompressed, compressed, .{
        .max_block_size = 64 * 1024,
    });
}

test "raw text file compression" {
    const uncompressed = @embedFile("testdata/plane_scene.txt");
    const compressed_indep = @embedFile("testdata/plane_scene.raw.lz4");

    try testExpectCompress(uncompressed, compressed_indep, .{
        .max_block_size = 64 * 1024,
    });
}

test "raw large file compression" {
    const uncompressed = @embedFile("testdata/buncha_floats.bin");
    const compressed_indep = @embedFile("testdata/buncha_floats.raw.lz4");

    try testExpectCompress(uncompressed, compressed_indep, .{
        .max_block_size = 64 * 1024,
    });
}
