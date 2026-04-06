# lz4u - LZ4 (For) You

lz4u is an LZ4 compressor and decompressor library and tool implementation written in Zig.

Its defining trait is having been made for the `std.Io.Reader` and `std.Io.Writer` interfaces.

Zig 0.15 is required.

## Installing as a `build.zig.zon` package

To install lz4u in your Zig project run:
```sh
zig fetch --save-exact=lz4u git+https://github.com/lateleite/lz4u.git
```

Then in your `build.zig` file:
```zig
pub fn build(b: *std.Build) !void {
    // ...
    // Add a reference to the package you've just fetched...
    const dep_lz4u = b.dependency("lz4u", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_lz4u = dep_lz4u.module("lz4u");

    // ...then load its module into your own
    const your_module = b.addModule(.{
        // ...
        .imports = &.{
            .{ .name = "lz4u", .module = mod_lz4u },
        },
    }),
    // ...
}
```

## Usage

### Decompressor

How to load a file from filesystem, decompress and write it to the filesystem again:

```zig
const std = @import("std");
const lz4u = @import("lz4u");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var in_file = try std.fs.cwd().openFile("compressed_file.txt.lz4", .{ .mode = .read_only });
    defer in_file.close();

    var out_file = try std.fs.cwd().createFile("decompresed_result.txt", .{});
    defer out_file.close();

    // there must be at least `queryInCapacity()` memory available for the reader to work 
    const reader_buf = try arena_alloc.alloc(u8, lz4u.Decompress.queryInCapacity());
    var reader = in_file.reader(reader_buf);

    // there must be at least `queryOutCapacity()` memory available for the writer to work 
    const writer_buf = try arena_alloc.alloc(u8, lz4u.Decompress.queryOutCapacity());
    var writer = out_file.writer(writer_buf);

    // `decompressor_buf` is optional, but it may boost performance by reducing syscalls.
    const decompressor_buf = try arena_alloc.alloc(u8, lz4u.min_indirect_buffer_len);
    var decompressor: lz4u.Decompress = .init(&reader.interface, decompressor_buf, .{ .verify_checksum = true });
    //var decompressor: lz4u.Decompress = .init(&reader.interface, &.{}, .{ .verify_checksum = true });

    defer writer.interface.flush() catch {};

    _ = decompressor.reader.streamRemaining(&writer.interface) catch |err| {
        if (decompressor.err) |dec_err| {
            // you can handle the decompressor specific error here
            return dec_err;
        } else {
            // or handle some std.Io error
            return err;
        }
    };
}
```

### Compressor

How to load a file from filesystem, compress it and write it to the filesystem again:

```zig

const std = @import("std");
const lz4u = @import("lz4u");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var in_file = try std.fs.cwd().openFile("my_uncompressed_tarball.tar", .{ .mode = .read_only });
    defer in_file.close();

    var out_file = try std.fs.cwd().createFile("out_compressed_tarball.tar.lz4", .{});
    defer out_file.close();

    // the compressor's options
    const compress_options: lz4u.Compress.Options = .{
        // a block's maximum memory size
        .max_block_size = .@"1MB",
        // if enabled, the decompressed data has its checksum verified
        .should_checksum_frame = true,
        // if enabled, blocks in compressed form have its checksum verified
        .should_checksum_block = false,
        // do blocks share the window buffer between them?
        .independent_blocks = true,
        // optional field that tells decompressors the exact size of the decompressed data
        .content_size_hint = null,
    };

    // reader's buffer may have any size, the compressor does not care.
    const reader_buf = try arena_alloc.alloc(u8, 8196);
    var reader = in_file.reader(reader_buf);

    // however, the writer's buffer must be at least `queryOutCapacity()` long`
    const writer_buf = try arena_alloc.alloc(u8, lz4u.Compress.queryOutCapacity(compress_options));
    var writer = out_file.writer(writer_buf);

    // a window buffer `lz4u.max_window_len` long must always be provided, regardless of block dependency
    const window_buf = try arena_alloc.alloc(u8, lz4u.max_window_len);

    var compressor: lz4u.Compress = try .init(&writer.interface, window_buf, compress_options);

    _ = try compressor.writer.sendFileAll(&reader, .unlimited);

    // you may flush the compressor's writer buffer at anytime,
    // however its resulting blocks may not be optimally compressed.
    try compressor.writer.flush();

    // tell the compressor you're done compressing data.
    // any new write will fail.
    // (if you wish to compress a new stream, you'll have to reinitialize the compressor.)
    try compressor.finish();

    try writer.interface.flush();
}
```

## Performance

Unfortunatelly at this time, LZ4U is slower and less optimal than the original LZ4 library.

(This is an area that I wish to improve.)

Here's some benchmarks on a Ryzen 5 5600X:

- Decompressing a Linux 6.19.11 source code tarball (compressed with the original LZ4 with `lz4 linux-6.19.11.tar linux-6.19.11.tar.lz4`):

```sh
$ poop "lz4 -d -f linux-6.19.11.tar.lz4" "lz4u-dec linux-6.19.11.tar.lz4 linux-6.19.11.tar"
Benchmark 1 (3 runs): lz4 -d -f linux-6.19.11.tar.lz4
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          11.5s  ± 2.39s     9.26s  … 14.0s           0 ( 0%)        0%
  peak_rss           33.2MB ±  464KB    32.7MB … 33.6MB          0 ( 0%)        0%
  cpu_cycles         3.01G  ±  105M     2.89G  … 3.08G           0 ( 0%)        0%
  instructions       9.03G  ± 2.14K     9.03G  … 9.03G           0 ( 0%)        0%
  cache_references    138M  ±  269K      137M  …  138M           0 ( 0%)        0%
  cache_misses       1.73M  ±  106K     1.61M  … 1.80M           0 ( 0%)        0%
  branch_misses      26.5M  ± 17.0K     26.4M  … 26.5M           0 ( 0%)        0%
Benchmark 2 (3 runs): lz4u-dec linux-6.19.11.tar.lz4 linux-6.19.11.tar
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          12.0s  ±  926ms    10.9s  … 12.7s           0 ( 0%)          +  4.2% ± 35.8%
  peak_rss           14.9MB ±  987KB    13.9MB … 15.8MB          0 ( 0%)        ⚡- 55.0% ±  5.3%
  cpu_cycles         10.8G  ± 15.4M     10.7G  … 10.8G           0 ( 0%)        💩+257.7% ±  5.7%
  instructions       23.7G  ±  629      23.7G  … 23.7G           0 ( 0%)        💩+162.2% ±  0.0%
  cache_references    135M  ±  579K      134M  …  135M           0 ( 0%)        ⚡-  2.2% ±  0.7%
  cache_misses       2.00M  ±  696K     1.58M  … 2.81M           0 ( 0%)          + 16.0% ± 65.3%
  branch_misses       255M  ±  308K      255M  …  255M           0 ( 0%)        💩+864.2% ±  1.9%
```

- Decompressing a Linux 6.19.11 source code tarball:

```sh
$ poop "lz4 -BI -B7 -f linux-6.19.11.tar linux-6.19.11.tar.lz4" "lz4u-enc -t independent -s 4MB -f linux-6.19.11.tar linux-6.19.11.tar.lz4"
Benchmark 1 (4 runs): lz4 -BI -B7 -f linux-6.19.11.tar linux-6.19.11.tar.lz4
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.55s  ±  409ms    1.06s  … 2.05s           0 ( 0%)        0%
  peak_rss           32.6MB ± 1.47MB    31.0MB … 34.1MB          0 ( 0%)        0%
  cpu_cycles         8.89G  ± 28.5M     8.86G  … 8.93G           0 ( 0%)        0%
  instructions       15.8G  ± 36.1K     15.8G  … 15.8G           0 ( 0%)        0%
  cache_references    358M  ± 5.96M      353M  …  366M           0 ( 0%)        0%
  cache_misses       6.51M  ±  691K     5.53M  … 7.14M           1 (25%)        0%
  branch_misses       150M  ±  137K      150M  …  151M           0 ( 0%)        0%
Benchmark 2 (3 runs): lz4u-enc -t independent -s 4MB -f linux-6.19.11.tar linux-6.19.11.tar.lz4
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          6.17s  ±  209ms    6.04s  … 6.41s           0 ( 0%)        💩+297.6% ± 43.4%
  peak_rss           2.17MB ± 2.36KB    2.17MB … 2.17MB          0 ( 0%)        ⚡- 93.3% ±  6.9%
  cpu_cycles         23.3G  ± 55.3M     23.2G  … 23.3G           0 ( 0%)        💩+161.8% ±  0.9%
  instructions       62.4G  ±  565      62.4G  … 62.4G           0 ( 0%)        💩+296.3% ±  0.0%
  cache_references    465M  ± 9.19M      458M  …  476M           0 ( 0%)        💩+ 29.7% ±  4.1%
  cache_misses       11.6M  ±  736K     11.1M  … 12.5M           0 ( 0%)        💩+ 78.4% ± 21.4%
  branch_misses       233M  ± 3.27M      230M  …  236M           0 ( 0%)        💩+ 55.0% ±  2.7%
```

## Credits

- [The authors of Zig's standard library flate implementation](https://codeberg.org/ziglang/zig/commits/branch/master/lib/std/compress/flate)

- [Yann Collet's original LZ4 implementation](https://github.com/lz4/lz4)

- [Yours truly](https://leite.ee) for putting this library together.

## License

All code here is released to public domain or under the BSD Zero Clause license, choose whichever you prefer.
