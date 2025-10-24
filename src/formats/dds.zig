const color = @import("../color.zig");
const FormatInterface = @import("../FormatInterface.zig");
const Image = @import("../Image.zig");
// const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const std = @import("std");
const io = @import("../io.zig");
const utils = @import("../utils.zig");
const builtin = @import("builtin");

const DDS_FILE_MAGIC = "DDS ";

const Header = extern struct {
    size: u32 = 124,
    flags: StructFlags,
    height: u32,
    width: u32,
    pitchOrLinearSize: u32, // don't rely on this, compute yourself
    depth: u32,
    mipMapCount: u32,
    reserved1: [11]u32,
    pf: PixelFormat,
    caps: CapFlags,
    caps2: CapFlags2,
    caps3: u32, // unused
    caps4: u32, // unused
    reserved2: u32,
};

pub const CapFlags = packed struct(u32) {
    unused1: u3 = 0,
    complex: bool,
    unused2: u8 = 0,
    texture: bool = true, // required
    unused3: u9 = 0,
    mipmap: bool,
    unused4: u9 = 0,
};

pub const CapFlags2 = packed struct(u32) {
    unused1: u9 = 0,
    cubemap: bool, // required for a cubemap
    cubemapPositiveX: bool,
    cubemapNegativeX: bool,
    cubemapPositiveY: bool,
    cubemapNegativeY: bool,
    cubemapPositiveZ: bool,
    cubemapNegativeZ: bool,
    unused2: u5 = 0,
    cubemapVolume: bool, // required for a volume texture
    unused3: u10 = 0,
};

pub const StructFlags = packed struct(u32) {
    caps: bool = true, // required, don't rely on this for reading
    height: bool = true, // required
    width: bool = true, // required
    pitch: bool, // required if pitch is provided for uncompressed textures
    unused1: u8 = 0,
    pixelFormat: bool = true, // required, don't rely on this for reading
    unused2: u4 = 0,
    mipMap: bool, // required if mipmaps are present, don't rely on this for reading
    unused3: u5 = 0,
    linarSize: bool, // required if pitch is provided for compressed textures
    unused4: u3 = 0,
    depth: bool, // required for depth textures
    unused5: u4 = 0,
};

const HeaderDXT10 = extern struct {};

const PixelFormat = extern struct {
    size: u32 = 32,
    flags: PixelFlags,
    fourCC: [4]u8, // fourcc in flags must be set
    rgbBitCount: u32, // rgb, luminance or yuv in flags must be set
    rBitMask: u32,
    gBitMask: u32,
    bBitMask: u32,
    aBitMask: u32, // one of alpha or alphaPixels in flags must be set
};

pub const PixelFlags = packed struct(u32) {
    alphaPixels: bool, // rBitMask, gBitMask, bBitMask, aBitMask are valid (?)
    alpha: bool, // legacy: rgbBitCount and aBitMask are valid
    fourCC: bool, // fourCC is valid
    unused1: u3 = 0,
    rgb: bool, // rgbBitCount and the four {rgba}BitMask fields are valid
    unused2: u2 = 0,
    yuv: bool, // legacy: {rgb}BitMask fields are valid and used for yuv
    unused3: u7 = 0,
    luminance: bool, // legacy: rgbBitCount and rBitMask are valid. if alphaPixels is set: 2 channel DDS (?)
    unused4: u14 = 0,
};

const FourCC = enum { DXT1, DXT2, DXT3, DXT4, DXT5 };

// fast and loose, hence not pub
fn bitIndex(Source: type, Dest: type, value: Source, index: usize) Dest {
    const nbits = @typeInfo(Dest).int.bits;
    const shift = index * nbits;
    return @truncate(value >> @intCast(shift));
}

// fast and loose, hence not pub
// also ha ha INTerpolate
fn interpolate(T: type, from: T, to: T, index: usize, steps: usize) T {
    return @truncate((steps - index) * @as(usize, from) / steps + index * @as(usize, to) / steps);
}

pub const DDS = struct {
    header: Header = undefined,
    header10: HeaderDXT10 = undefined,

    pub const EncoderOptions = struct {};

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .formatDetect = formatDetect,
            .readImage = readImage,
            .writeImage = writeImage,
        };
    }

    pub fn formatDetect(read_stream: *io.ReadStream) Image.ReadError!bool {
        const reader = read_stream.reader();
        const magic_number = try reader.peek(4);
        return std.mem.eql(u8, magic_number[0..], DDS_FILE_MAGIC[0..]);
    }

    pub fn readImage(allocator: std.mem.Allocator, read_stream: *io.ReadStream) Image.ReadError!Image {
        var image: Image = .{};
        errdefer image.deinit(allocator);

        var dds: DDS = .{};

        image.pixels = try dds.read(allocator, read_stream);
        image.width = dds.header.width;
        image.height = dds.header.height;
        return image;
    }

    pub fn writeImage(allocator: std.mem.Allocator, write_stream: *io.WriteStream, image: Image, encoder_options: Image.EncoderOptions) Image.WriteError!void {
        _ = allocator;
        _ = write_stream;
        _ = image;
        _ = encoder_options;
        return Image.ReadError.Unsupported;
    }

    pub fn read(self: *DDS, allocator: std.mem.Allocator, read_stream: *io.ReadStream) Image.ReadError!color.PixelStorage {
        // read header magic value
        const reader = read_stream.reader();

        const magic = reader.take(DDS_FILE_MAGIC.len) catch return Image.ReadError.InvalidData;
        if (!std.mem.eql(u8, magic, DDS_FILE_MAGIC[0..])) {
            return Image.ReadError.InvalidData;
        }

        self.header = reader.takeStruct(Header, .little) catch return Image.ReadError.InvalidData;
        std.debug.print("{any}\n", .{self.header});

        if (self.header.size != 124) return Image.ReadError.InvalidData;
        if (self.header.pf.size != 32) return Image.ReadError.InvalidData;

        if (self.header.pf.flags.fourCC) {
            std.debug.print("fcc: {s}\n", .{self.header.pf.fourCC[0..]});
            const fourCC = std.meta.stringToEnum(FourCC, self.header.pf.fourCC[0..]) orelse {
                return Image.ReadError.Unsupported;
            };
            // only difference bewteen DXT2/3 and DXT4/5 is premultiplied alpha (handled by app)
            return switch (fourCC) {
                .DXT1 => try self.readBC1(allocator, reader),
                .DXT2, .DXT3 => try self.readBC2(allocator, reader),
                .DXT4, .DXT5 => try self.readBC3(allocator, reader),
            };
        } else if (self.header.pf.flags.rgb and self.header.pf.flags.alphaPixels) {
            return switch (self.header.pf.rgbBitCount) {
                32 => try self.readUncompressedRGBA(allocator, reader),
                else => {
                    std.debug.print("rgbbitcount {}\n", .{self.header.pf.rgbBitCount});
                    return Image.ReadError.Unsupported;
                },
            };
        } else if (self.header.pf.flags.rgb) {
            return switch (self.header.pf.rgbBitCount) {
                24 => try self.readUncompressedRGB(allocator, reader, 24),
                32 => try self.readUncompressedRGB(allocator, reader, 32),
                else => {
                    std.debug.print("rgbbitcount {}\n", .{self.header.pf.rgbBitCount});
                    return Image.ReadError.Unsupported;
                },
            };
        } else {
            return Image.ReadError.Unsupported;
        }
    }

    fn readBC3(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgba32, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const block_width = (self.header.width / 4);
        const block_height = (self.header.height / 4);
        const num_blocks = block_width * block_height;

        for (0..num_blocks) |block_id| {
            const ref_alpha_0 = try reader.takeByte();
            const ref_alpha_1 = try reader.takeByte();
            const idxs_alpha = try reader.takeInt(u48, .little);
            const ref_color_0 = try reader.takeInt(u16, .little);
            const ref_color_1 = try reader.takeInt(u16, .little);
            const idxs_color = try reader.takeInt(u32, .little);
            var alphas: [16]u8 = undefined;

            if (ref_alpha_0 > ref_alpha_1) {
                alphas[0] = ref_alpha_0;
                alphas[1] = ref_alpha_1;
                alphas[2] = interpolate(u8, ref_alpha_0, ref_alpha_1, 1, 7);
                alphas[3] = interpolate(u8, ref_alpha_0, ref_alpha_1, 2, 7);
                alphas[4] = interpolate(u8, ref_alpha_0, ref_alpha_1, 3, 7);
                alphas[5] = interpolate(u8, ref_alpha_0, ref_alpha_1, 4, 7);
                alphas[6] = interpolate(u8, ref_alpha_0, ref_alpha_1, 5, 7);
                alphas[7] = interpolate(u8, ref_alpha_0, ref_alpha_1, 6, 7);
            } else {
                alphas[0] = ref_alpha_0;
                alphas[1] = ref_alpha_1;
                alphas[2] = interpolate(u8, ref_alpha_0, ref_alpha_1, 1, 5);
                alphas[3] = interpolate(u8, ref_alpha_0, ref_alpha_1, 2, 5);
                alphas[4] = interpolate(u8, ref_alpha_0, ref_alpha_1, 3, 5);
                alphas[5] = interpolate(u8, ref_alpha_0, ref_alpha_1, 4, 5);
                alphas[6] = 0;
                alphas[7] = 255;
            }
            var colors: [4]color.Rgb24 = undefined;
            colors[0] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_0)));
            colors[1] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_1)));
            const c0 = @as(color.Rgb565, @bitCast(ref_color_0));
            const c1 = @as(color.Rgb565, @bitCast(ref_color_1));
            colors[2] = color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 1, 3),
                .g = interpolate(u6, c0.g, c1.g, 1, 3),
                .b = interpolate(u5, c0.b, c1.b, 1, 3),
            });
            colors[3] = color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 2, 3),
                .g = interpolate(u6, c0.g, c1.g, 2, 3),
                .b = interpolate(u5, c0.b, c1.b, 2, 3),
            });

            const x_start = (block_id % block_width) * 4;
            const y_start = (block_id / block_width) * 4;

            for (0..4) |y| {
                for (0..4) |x| {
                    const rgb = bitIndex(u32, u2, idxs_color, y * 4 + x);
                    const a = bitIndex(u48, u3, idxs_alpha, y * 4 + x);
                    pixels.rgba32[(y_start + y) * self.header.width + (x_start + x)] = .{
                        .r = colors[rgb].r,
                        .g = colors[rgb].g,
                        .b = colors[rgb].b,
                        .a = alphas[a],
                    };
                }
            }
        }

        return pixels;
    }
    fn readBC2(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgba32, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const block_width = (self.header.width / 4);
        const block_height = (self.header.height / 4);
        const num_blocks = block_width * block_height;

        for (0..num_blocks) |block_id| {
            const alphas = try reader.takeInt(u64, .little);
            const ref_color_0 = try reader.takeInt(u16, .little);
            const ref_color_1 = try reader.takeInt(u16, .little);
            const idxs_color = try reader.takeInt(u32, .little);

            var colors: [4]color.Rgb24 = undefined;
            colors[0] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_0)));
            colors[1] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_1)));
            const c0 = @as(color.Rgb565, @bitCast(ref_color_0));
            const c1 = @as(color.Rgb565, @bitCast(ref_color_1));
            colors[2] = color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 1, 3),
                .g = interpolate(u6, c0.g, c1.g, 1, 3),
                .b = interpolate(u5, c0.b, c1.b, 1, 3),
            });
            colors[3] = color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 2, 3),
                .g = interpolate(u6, c0.g, c1.g, 2, 3),
                .b = interpolate(u5, c0.b, c1.b, 2, 3),
            });

            const x_start = (block_id % block_width) * 4;
            const y_start = (block_id / block_width) * 4;

            for (0..4) |y| {
                for (0..4) |x| {
                    const rgb = bitIndex(u32, u2, idxs_color, y * 4 + x);
                    const a = bitIndex(u64, u4, alphas, y * 4 + x);
                    pixels.rgba32[(y_start + y) * self.header.width + (x_start + x)] = .{
                        .r = colors[rgb].r,
                        .g = colors[rgb].g,
                        .b = colors[rgb].b,
                        .a = interpolate(u8, 0, 255, a, 16),
                    };
                }
            }
        }

        return pixels;
    }

    fn readBC1(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgba32, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const block_width = (self.header.width / 4);
        const block_height = (self.header.height / 4);
        const num_blocks = block_width * block_height;

        for (0..num_blocks) |block_id| {
            const ref_color_0 = try reader.takeInt(u16, .little);
            const ref_color_1 = try reader.takeInt(u16, .little);
            const idxs_color = try reader.takeInt(u32, .little);

            var colors: [4]color.Rgb24 = undefined;
            colors[0] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_0)));
            colors[1] = color.Rgb24.from.color(@as(color.Rgb565, @bitCast(ref_color_1)));
            const c0 = @as(color.Rgb565, @bitCast(ref_color_0));
            const c1 = @as(color.Rgb565, @bitCast(ref_color_1));

            if (ref_color_0 > ref_color_1) {
                colors[3] = color.Rgb24.from.color(color.Rgb565{
                    .r = interpolate(u5, c0.r, c1.r, 2, 3),
                    .g = interpolate(u6, c0.g, c1.g, 2, 3),
                    .b = interpolate(u5, c0.b, c1.b, 2, 3),
                });
                colors[2] = color.Rgb24.from.color(color.Rgb565{
                    .r = interpolate(u5, c0.r, c1.r, 1, 3),
                    .g = interpolate(u6, c0.g, c1.g, 1, 3),
                    .b = interpolate(u5, c0.b, c1.b, 1, 3),
                });
            } else {
                colors[2] = color.Rgb24.from.color(color.Rgb565{
                    .r = interpolate(u5, c0.r, c1.r, 1, 2),
                    .g = interpolate(u6, c0.g, c1.g, 1, 2),
                    .b = interpolate(u5, c0.b, c1.b, 1, 2),
                });
                colors[3] = color.Rgb24.from.rgb(0, 0, 0);
            }

            const has_alpha = !(ref_color_0 > ref_color_1);

            const x_start = (block_id % block_width) * 4;
            const y_start = (block_id / block_width) * 4;

            for (0..4) |y| {
                for (0..4) |x| {
                    const rgb = bitIndex(u32, u2, idxs_color, y * 4 + x);
                    pixels.rgba32[(y_start + y) * self.header.width + (x_start + x)] = .{
                        .r = colors[rgb].r,
                        .g = colors[rgb].g,
                        .b = colors[rgb].b,
                        .a = if (has_alpha and rgb == 3) 0 else 255,
                    };
                }
            }
        }

        return pixels;
    }

    fn readUncompressedRGBA(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgba32, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        for (0..self.header.height) |y| {
            for (0..self.header.width) |x| {
                const value: u32 = try reader.takeInt(u32, .little);
                pixels.rgba32[y * self.header.width + x] = .{
                    .r = @truncate((value & self.header.pf.rBitMask) >> @intCast(@ctz(self.header.pf.rBitMask))),
                    .g = @truncate((value & self.header.pf.gBitMask) >> @intCast(@ctz(self.header.pf.gBitMask))),
                    .b = @truncate((value & self.header.pf.bBitMask) >> @intCast(@ctz(self.header.pf.bBitMask))),
                    .a = @truncate((value & self.header.pf.aBitMask) >> @intCast(@ctz(self.header.pf.aBitMask))),
                };
            }
        }
        return pixels;
    }

    fn readUncompressedRGB(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime bitCount: u32) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgb24, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const T = @Type(.{ .int = .{ .bits = bitCount, .signedness = .unsigned } });

        for (0..self.header.height) |y| {
            for (0..self.header.width) |x| {
                const value = try reader.takeInt(T, .little);
                pixels.rgb24[y * self.header.width + x] = .{
                    .r = @truncate((value & self.header.pf.rBitMask) >> @intCast(@ctz(self.header.pf.rBitMask))),
                    .g = @truncate((value & self.header.pf.gBitMask) >> @intCast(@ctz(self.header.pf.gBitMask))),
                    .b = @truncate((value & self.header.pf.bBitMask) >> @intCast(@ctz(self.header.pf.bBitMask))),
                };
            }
        }
        return pixels;
    }
};
