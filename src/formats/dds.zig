const color = @import("../color.zig");
const FormatInterface = @import("../FormatInterface.zig");
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const Image = @import("../Image.zig");
const std = @import("std");
const io = @import("../io.zig");

const e = @import("dds/enums.zig");
const MiscFlag2 = e.MiscFlag2;
const D3D10ResourceDimension = e.D3D10ResourceDimension;
const DXGIFormat = e.DXGIFormat;

const bc = @import("dds/bc.zig");

const DDS_FILE_MAGIC = "DDS ";

const Header = extern struct {
    size: u32 = 124,
    flags: HeaderFlags,
    height: u32,
    width: u32,
    pitchOrLinearSize: u32, // don't rely on this, compute yourself
    depth: u32,
    mipMapCount: u32,
    reserved1: [11]u32,
    pf: PxFmt,
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

pub const HeaderFlags = packed struct(u32) {
    caps: bool = true, // required, don't rely on this for reading
    height: bool = true, // required
    width: bool = true, // required
    pitch: bool, // required if pitch is provided for uncompressed textures
    unused1: u8 = 0,
    pixelFormat: bool = true, // required, don't rely on this for reading
    unused2: u4 = 0,
    mipMap: bool, // required if mipmaps are present, don't rely on this for reading
    unused3: u5 = 0,
    linearSize: bool, // required if pitch is provided for compressed textures (?)
    unused4: u3 = 0,
    depth: bool, // required for depth textures
    unused5: u4 = 0,
};

const HeaderDXT10 = extern struct {
    dxgiFormat: DXGIFormat,
    resourceDimension: D3D10ResourceDimension,
    miscFlag: MiscFlag,
    arraySize: u32,
    miscFlags2: MiscFlag2,
};

const MiscFlag = packed struct(u32) {
    unused1: u2,
    texturecube: bool,
    unused2: u29,
};

const PxFmt = extern struct {
    size: u32 = 32,
    flags: PxFlags,
    fourCC: [4]u8, // fourcc in flags must be set
    rgbBitCount: u32, // rgb, luminance or yuv in flags must be set
    rBitMask: u32,
    gBitMask: u32,
    bBitMask: u32,
    aBitMask: u32, // one of alpha or alphaPixels in flags must be set
};

pub const PxFlags = packed struct(u32) {
    alphaPixels: bool, // rBitMask, gBitMask, bBitMask, aBitMask are valid (?)
    alpha: bool, // legacy: rgbBitCount and aBitMask are valid
    fourCC: bool, // fourCC is valid
    unused1: u3 = 0,
    rgb: bool, // rgbBitCount and the four {rgba}BitMask fields are valid
    unused2: u2 = 0,
    yuv: bool, // legacy: {rgb}BitMask fields are valid and used for yuv
    unused3: u7 = 0,
    luminance: bool, // legacy: rgbBitCount and rBitMask are valid. if alphaPixels is set: 2 channel Dds (?)
    unused4: u14 = 0,
};

const FourCC = enum { DXT1, DXT2, DXT3, DXT4, DXT5, DX10 };

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
        const reader = read_stream.reader();

        const magic = reader.take(DDS_FILE_MAGIC.len) catch return Image.ReadError.InvalidData;
        if (!std.mem.eql(u8, magic, DDS_FILE_MAGIC[0..])) {
            return Image.ReadError.InvalidData;
        }

        self.header = reader.takeStruct(Header, .little) catch return Image.ReadError.InvalidData;

        if (self.header.size != 124) return Image.ReadError.InvalidData;
        if (self.header.pf.size != 32) return Image.ReadError.InvalidData;

        if (self.header.pf.flags.fourCC) {
            const fourCC = std.meta.stringToEnum(FourCC, self.header.pf.fourCC[0..]) orelse {
                return Image.ReadError.Unsupported;
            };

            // only difference bewteen DXT2/3 and DXT4/5 is premultiplied alpha (handled by app)
            return switch (fourCC) {
                .DXT1 => try self.readBC(allocator, reader, bc.BC1Block),
                .DXT2, .DXT3 => try self.readBC(allocator, reader, bc.BC2Block),
                .DXT4, .DXT5 => try self.readBC(allocator, reader, bc.BC3Block),
                .DX10 => try self.readD10(allocator, reader),
            };
        } else {
            return self.readNonFourCC(allocator, reader);
        }
    }

    fn readD10(self: *DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        _ = allocator;
        self.header10 = reader.takeStruct(HeaderDXT10, .little) catch return Image.ReadError.InvalidData;
        return switch (self.header10.dxgiFormat) {
            else => Image.ReadError.Unsupported,
        };
    }

    fn readBC(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader, BCBlock: type) Image.ReadError!color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, .rgba32, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const block_width = (self.header.width / 4);
        const block_height = (self.header.height / 4);
        const num_blocks = block_width * block_height;

        for (0..num_blocks) |block_id| {
            const x_start = (block_id % block_width) * 4;
            const y_start = (block_id / block_width) * 4;
            try BCBlock.decode(reader, pixels, x_start, y_start, self.header.width);
        }
        return pixels;
    }

    pub const FormatData = struct {
        bitCount: u32,
        rMask: u32 = 0,
        gMask: u32 = 0,
        bMask: u32 = 0,
        aMask: u32 = 0,
        alphaPixels: bool = false,
        alpha: bool = false,
        rgb: bool = false,
        yuv: bool = false,
        luminance: bool = false,

        pub fn asHash(self: FormatData) u32 {
            var adler = std.hash.Adler32{};
            adler.update(std.mem.asBytes(&self.bitCount));
            adler.update(std.mem.asBytes(&self.rMask));
            adler.update(std.mem.asBytes(&self.gMask));
            adler.update(std.mem.asBytes(&self.bMask));
            adler.update(std.mem.asBytes(&self.aMask));
            adler.update(std.mem.asBytes(&@as(u32, @intFromBool(self.alphaPixels))));
            adler.update(std.mem.asBytes(&@as(u32, @intFromBool(self.alpha))));
            adler.update(std.mem.asBytes(&@as(u32, @intFromBool(self.rgb))));
            adler.update(std.mem.asBytes(&@as(u32, @intFromBool(self.yuv))));
            adler.update(std.mem.asBytes(&@as(u32, @intFromBool(self.luminance))));
            return adler.adler;
        }

        pub const a8r8g8b8: FormatData = .{ .bitCount = 32, .rMask = 0xff0000, .gMask = 0xff00, .bMask = 0xff, .aMask = 0xff000000, .alphaPixels = true, .rgb = true };
        pub const x8r8g8b8: FormatData = .{ .bitCount = 32, .rMask = 0xff0000, .gMask = 0xff00, .bMask = 0xff, .rgb = true };
        pub const r8g8b8: FormatData = .{ .bitCount = 24, .rMask = 0xff0000, .gMask = 0xff00, .bMask = 0xff, .rgb = true };
        pub const a8l8: FormatData = .{ .bitCount = 16, .rMask = 0xff, .aMask = 0xff00, .alphaPixels = true, .luminance = true };
        pub const l8: FormatData = .{ .bitCount = 8, .rMask = 0xff, .luminance = true };
    };

    pub const FormatInfo = struct {
        bitCount: u32,
        fmt: PixelFormat,
        rloc: ?[]const u8 = null,
        gloc: ?[]const u8 = null,
        bloc: ?[]const u8 = null,
        aloc: ?[]const u8 = null,

        pub const a8r8g8b8: FormatInfo = .{ .bitCount = 32, .fmt = .rgba32, .rloc = "r", .gloc = "g", .bloc = "b", .aloc = "a" };
        pub const x8r8g8b8: FormatInfo = .{ .bitCount = 32, .fmt = .rgb24, .rloc = "r", .gloc = "g", .bloc = "b" };
        pub const r8g8b8: FormatInfo = .{ .bitCount = 24, .fmt = .rgb24, .rloc = "r", .gloc = "g", .bloc = "b" };
        pub const a8l8: FormatInfo = .{ .bitCount = 16, .fmt = .grayscale8Alpha, .rloc = "value", .aloc = "alpha" };
        pub const l8: FormatInfo = .{ .bitCount = 8, .fmt = .grayscale8, .rloc = "value" };
    };

    fn readNonFourCC(self: DDS, allocator: std.mem.Allocator, reader: *std.Io.Reader) Image.ReadError!color.PixelStorage {
        const pf = self.header.pf;
        const cnt = pf.rgbBitCount; // should always be valid at this point
        const f = pf.flags;

        const fmtHasher = FormatData{
            .bitCount = cnt,
            .rMask = if (f.rgb or f.yuv or f.luminance) pf.rBitMask else 0,
            .gMask = if (f.rgb or f.yuv) pf.gBitMask else 0,
            .bMask = if (f.rgb or f.yuv) pf.bBitMask else 0,
            .aMask = if (f.alphaPixels or f.alpha) pf.aBitMask else 0,
            .alphaPixels = f.alphaPixels,
            .alpha = f.alpha,
            .rgb = f.rgb,
            .yuv = f.yuv,
            .luminance = f.luminance,
        };

        return switch (fmtHasher.asHash()) {
            FormatData.a8r8g8b8.asHash() => try self.readUncompressed(.a8r8g8b8, .a8r8g8b8, allocator, reader),
            FormatData.x8r8g8b8.asHash() => try self.readUncompressed(.x8r8g8b8, .x8r8g8b8, allocator, reader),
            FormatData.r8g8b8.asHash() => try self.readUncompressed(.r8g8b8, .r8g8b8, allocator, reader),
            FormatData.a8l8.asHash() => try self.readUncompressed(.a8l8, .a8l8, allocator, reader),
            FormatData.l8.asHash() => try self.readUncompressed(.l8, .l8, allocator, reader),
            else => Image.ReadError.Unsupported,
        };
    }

    fn readUncompressed(self: DDS, comptime data: FormatData, comptime info: FormatInfo, allocator: std.mem.Allocator, reader: *std.Io.Reader) !color.PixelStorage {
        const pixels = try color.PixelStorage.init(allocator, info.fmt, @as(usize, self.header.width) * @as(usize, self.header.height));
        errdefer pixels.deinit(allocator);

        const IntType = @Type(.{ .int = .{ .bits = info.bitCount, .signedness = .unsigned } });

        for (0..self.header.height) |y| {
            for (0..self.header.width) |x| {
                const value: IntType = try reader.takeInt(IntType, .little);
                const entry = &@field(pixels, @tagName(info.fmt))[y * self.header.width + x];

                if (info.rloc) |rl| @field(entry, rl) = @truncate((value & data.rMask) >> @intCast(@ctz(data.rMask)));
                if (info.gloc) |gl| @field(entry, gl) = @truncate((value & data.gMask) >> @intCast(@ctz(data.gMask)));
                if (info.bloc) |bl| @field(entry, bl) = @truncate((value & data.bMask) >> @intCast(@ctz(data.bMask)));
                if (info.aloc) |al| @field(entry, al) = @truncate((value & data.aMask) >> @intCast(@ctz(data.aMask)));
            }
        }

        return pixels;
    }
};
