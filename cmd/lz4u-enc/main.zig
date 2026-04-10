const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log;
const process = std.process;

const argzon = @import("argzon");
const lz4u = @import("lz4u");

const cli = .{
    .name = "lz4u-enc",
    .description = "An LZ4 file compressing utility.",
    .positionals = .{
        .{
            .meta = .INPUT,
            .type = "string",
            .description = "The input path to the file to be compressed",
        },
        .{
            .meta = .OUTPUT,
            .type = "string",
            .description = "The output path to the final compressed file",
        },
    },
    .options = .{
        .{
            .short = 't',
            .long = "block-type",
            .type = "BlockType",
            .default = .dependent,
            .description = "Sets all block's dependency type",
        },
        .{
            .short = 's',
            .long = "block-max-size",
            .type = "BlockMaxSize",
            .default = .@"4MB",
            .description = "Sets all block's maximum byte size",
        },
    },
    .flags = .{
        .{
            .short = 'f',
            .long = "content-checksum",
            .description = "Enable frame content checksum",
        },
        .{
            .short = 'b',
            .long = "block-checksum",
            .description = "Enable block data checksum",
        },
        .{
            .short = 'c',
            .long = "content-size",
            .description = "Enable content size hint",
        },
    },
};

pub const BlockType = enum {
    dependent,
    independent,
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
        .enums = &.{
            BlockType,
            lz4u.Frame.BlockMaxSize,
        },
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

    const maybe_file_size: ?u64 = res: {
        if (args.flags.@"content-size") {
            if (in_file.getEndPos()) |end| {
                break :res end;
            } else |err| {
                log.warn("Failed to get size of file {s} with {t}, skipping size hint in LZ4 frame...", .{
                    in_path,
                    err,
                });
            }
        }
        break :res null;
    };

    const compress_options: lz4u.Frame.Compress.Options = .{
        .max_block_size = args.options.@"block-max-size",
        .should_checksum_frame = args.flags.@"content-checksum",
        .should_checksum_block = args.flags.@"block-checksum",
        .independent_blocks = switch (args.options.@"block-type") {
            .dependent => false,
            .independent => true,
        },
        .content_size_hint = maybe_file_size,
    };

    const reader_buf = try arena_alloc.alloc(u8, 8196);
    var reader = in_file.reader(reader_buf);

    const writer_buf = try arena_alloc.alloc(u8, lz4u.Frame.Compress.queryOutCapacity(compress_options));
    var writer = out_file.writer(writer_buf);

    const window_buf = try arena_alloc.alloc(u8, lz4u.max_window_len);

    var compressor: lz4u.Frame.Compress = try .init(&writer.interface, window_buf, compress_options);

    defer writer.interface.flush() catch |err| {
        process.fatal("Failed to flush data to {s} with {t}", .{ out_path, err });
    };
    defer compressor.writer.flush() catch |err| {
        process.fatal("Failed to compress data to {s} with {t}", .{ out_path, err });
    };

    const bytes_written = compressor.writer.sendFileAll(&reader, .unlimited) catch |err| {
        log.err("Failed to compress data with {t}", .{err});
        return err;
    };
    compressor.finish() catch |err| {
        log.err("Failed to finish compressed data with {t}", .{err});
        return err;
    };

    log.info("Compressed {B} to {s}", .{ bytes_written, out_path });
}
