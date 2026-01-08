const std = @import("std");
const PixelFormat = @import("../../pixel_format.zig").PixelFormat;
pub const fmtData: Formats = @import("./format_data.zon");

const Entry = struct {
    bitCount: u16,
    readInfo: ReadInfo,
    writeInfo: WriteInfo,
};

const Formats = struct {
    a8r8g8b8: Entry,
    x8r8g8b8: Entry,
    r8g8b8: Entry,
    a8l8: Entry,
    l8: Entry,
};

pub const ReadInfo = struct {
    rMask: u32 = 0,
    gMask: u32 = 0,
    bMask: u32 = 0,
    aMask: u32 = 0,
    alphaPixels: bool = false,
    alpha: bool = false,
    rgb: bool = false,
    yuv: bool = false,
    luminance: bool = false,

    // returning FormatMagic would be nice, but the compiler refuses (circular dep)
    pub fn toMagic(self: ReadInfo, bitCount: u32) u32 {
        var hasher = std.hash.Adler32{};
        hasher.update(std.mem.asBytes(&bitCount));
        inline for (@typeInfo(@TypeOf(self)).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .bool => hasher.update(std.mem.asBytes(&@as(u32, @intFromBool(@field(self, field.name))))),
                .int => hasher.update(std.mem.asBytes(&@field(self, field.name))),
                else => @compileError("Unexpected field type in ReadInfo"),
            }
        }
        return hasher.adler;
    }
};

pub const WriteInfo = struct {
    pixelFmt: PixelFormat,
    rloc: ?[]const u8 = null,
    gloc: ?[]const u8 = null,
    bloc: ?[]const u8 = null,
    aloc: ?[]const u8 = null,
};

pub const FormatMagic = enum(u32) {
    a8r8g8b8 = ReadInfo.toMagic(fmtData.a8r8g8b8.readInfo, fmtData.a8r8g8b8.bitCount),
    x8r8g8b8 = ReadInfo.toMagic(fmtData.x8r8g8b8.readInfo, fmtData.x8r8g8b8.bitCount),
    r8g8b8 = ReadInfo.toMagic(fmtData.r8g8b8.readInfo, fmtData.r8g8b8.bitCount),
    a8l8 = ReadInfo.toMagic(fmtData.a8l8.readInfo, fmtData.a8l8.bitCount),
    l8 = ReadInfo.toMagic(fmtData.l8.readInfo, fmtData.l8.bitCount),

    pub fn toInfo(comptime self: FormatMagic) Entry {
        return @field(fmtData, @tagName(self));
    }
};
