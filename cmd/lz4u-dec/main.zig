const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log;
const process = std.process;

const argzon = @import("argzon");
const lz4u = @import("lz4u");

const cli = .{
    .name = "lz4u-dec",
    .description = "An LZ4 file decompressor.",
    .positionals = .{
        .{
            .meta = .INPUT,
            .type = "string",
            .description = "The input path to the file to be decompressed",
        },
        .{
            .meta = .OUTPUT,
            .type = "string",
            .description = "The output path to the final file",
        },
    },
};

pub fn main() !void {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const Args = argzon.Args(cli, .{
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    var arg_str_iter = try process.argsWithAllocator(arena_alloc);
    const args = try Args.parse(arena_alloc, &arg_str_iter, stderr, .{ .is_gpa = false });

    const in_path = args.positionals.INPUT;
    var in_file = fs.cwd().openFile(in_path, .{ .mode = .read_only }) catch |err| {
        log.err("Failed to open input file {s} with {t}", .{ in_path, err });
        return err;
    };
    defer in_file.close();

    const out_path = args.positionals.OUTPUT;
    var out_file = fs.cwd().createFile(out_path, .{}) catch |err| {
        log.err("Failed to open output file {s} with {t}", .{ out_path, err });
        return err;
    };
    defer out_file.close();

    const bytes_to_read = try in_file.getEndPos();

    const reader_buf = try arena_alloc.alloc(u8, lz4u.Frame.Decompress.queryInCapacity());
    var reader = in_file.reader(reader_buf);

    const writer_buf = try arena_alloc.alloc(u8, lz4u.Frame.Decompress.queryOutCapacity());
    var writer = out_file.writer(writer_buf);

    const decompressor_buf = try arena_alloc.alloc(u8, lz4u.min_indirect_buffer_len);
    var decompressor: lz4u.Frame.Decompress = .init(&reader.interface, decompressor_buf, .{ .verify_checksum = true });

    defer writer.interface.flush() catch |err| {
        process.fatal("Failed to flush data to {s} with {t}", .{ out_path, err });
    };

    const bytes_written = decompressor.reader.streamRemaining(&writer.interface) catch |err| {
        if (decompressor.err) |dec_err| {
            log.err("Failed to stream LZ4 data with {t}, decompressor error: {t}", .{
                err,
                dec_err,
            });
            return dec_err;
        } else {
            log.err("Failed to stream LZ4 data with {t}", .{err});
            return err;
        }
    };

    log.info("Decompressed {B:.4}->{B:.4} to {s}", .{ bytes_to_read, bytes_written, out_path });
}
