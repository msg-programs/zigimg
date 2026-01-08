const color = @import("../../color.zig");
const std = @import("std");

// fast and loose
fn bitIndex(Source: type, Dest: type, value: Source, index: usize) Dest {
    const nbits = @typeInfo(Dest).int.bits;
    const shift = index * nbits;
    return @truncate(value >> @intCast(shift));
}

// fast and loose
fn interpolate(T: type, from: T, to: T, index: usize, steps: usize) T {
    return @intCast((steps - index) * @as(usize, from) / steps + index * @as(usize, to) / steps);
}

pub const BC1Block = packed struct(u64) {
    ref_color_0: u16,
    ref_color_1: u16,
    idxs_color: u32,

    fn getColorTableStd(self: BC1Block) [4]color.Rgb24 {
        const c0 = @as(color.Rgb565, @bitCast(self.ref_color_0));
        const c1 = @as(color.Rgb565, @bitCast(self.ref_color_1));

        return .{
            color.Rgb24.from.color(c0),
            color.Rgb24.from.color(c1),
            color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 1, 3),
                .g = interpolate(u6, c0.g, c1.g, 1, 3),
                .b = interpolate(u5, c0.b, c1.b, 1, 3),
            }),
            color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 2, 3),
                .g = interpolate(u6, c0.g, c1.g, 2, 3),
                .b = interpolate(u5, c0.b, c1.b, 2, 3),
            }),
        };
    }

    fn getColorTableAlpha(self: BC1Block) [4]color.Rgb24 {
        const c0 = @as(color.Rgb565, @bitCast(self.ref_color_0));
        const c1 = @as(color.Rgb565, @bitCast(self.ref_color_1));

        return .{
            color.Rgb24.from.color(c0),
            color.Rgb24.from.color(c1),
            color.Rgb24.from.color(color.Rgb565{
                .r = interpolate(u5, c0.r, c1.r, 1, 2),
                .g = interpolate(u6, c0.g, c1.g, 1, 2),
                .b = interpolate(u5, c0.b, c1.b, 1, 2),
            }),
            color.Rgb24.from.rgb(0, 0, 0),
        };
    }

    pub fn decode(reader: *std.Io.Reader, pixels: color.PixelStorage, bx: usize, by: usize, width: usize) !void {
        const block = try reader.takeStruct(BC1Block, .little);
        const colors = if (block.ref_color_0 > block.ref_color_1)
            block.getColorTableStd()
        else
            block.getColorTableAlpha();

        const has_alpha = !(block.ref_color_0 > block.ref_color_1);

        for (0..4) |y| {
            for (0..4) |x| {
                const rgb = bitIndex(u32, u2, block.idxs_color, y * 4 + x);
                pixels.rgba32[(by + y) * width + (bx + x)] = .{
                    .r = colors[rgb].r,
                    .g = colors[rgb].g,
                    .b = colors[rgb].b,
                    .a = if (has_alpha and rgb == 3) 0 else 255,
                };
            }
        }
    }
};

pub const BC2Block = packed struct(u128) {
    alphas: u64,
    bc1: BC1Block,

    pub fn decode(reader: *std.Io.Reader, pixels: color.PixelStorage, bx: usize, by: usize, width: usize) !void {
        const block = try reader.takeStruct(BC2Block, .little);
        const colors = block.bc1.getColorTableStd();

        for (0..4) |y| {
            for (0..4) |x| {
                const rgb = bitIndex(u32, u2, block.bc1.idxs_color, y * 4 + x);
                const a = bitIndex(u64, u4, block.alphas, y * 4 + x);
                pixels.rgba32[(by + y) * width + (bx + x)] = .{
                    .r = colors[rgb].r,
                    .g = colors[rgb].g,
                    .b = colors[rgb].b,
                    .a = interpolate(u8, 0, 255, a, 16),
                };
            }
        }
    }
};

pub const BC3Block = packed struct(u128) {
    ref_alpha_0: u8,
    ref_alpha_1: u8,
    idxs_alpha: u48,
    bc1: BC1Block,

    fn getAlphaTable(self: BC3Block) [8]u8 {
        return if (self.ref_alpha_0 > self.ref_alpha_1) .{
            self.ref_alpha_0,
            self.ref_alpha_1,
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 1, 7),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 2, 7),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 3, 7),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 4, 7),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 5, 7),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 6, 7),
        } else .{
            self.ref_alpha_0,
            self.ref_alpha_1,
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 1, 5),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 2, 5),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 3, 5),
            interpolate(u8, self.ref_alpha_0, self.ref_alpha_1, 4, 5),
            0,
            255,
        };
    }

    pub fn decode(reader: *std.Io.Reader, pixels: color.PixelStorage, bx: usize, by: usize, width: usize) !void {
        const block = try reader.takeStruct(BC3Block, .little);
        const alphas = block.getAlphaTable();
        const colors = block.bc1.getColorTableStd();

        for (0..4) |y| {
            for (0..4) |x| {
                const rgb = bitIndex(u32, u2, block.bc1.idxs_color, y * 4 + x);
                const a = bitIndex(u48, u3, block.idxs_alpha, y * 4 + x);
                pixels.rgba32[(by + y) * width + (bx + x)] = .{
                    .r = colors[rgb].r,
                    .g = colors[rgb].g,
                    .b = colors[rgb].b,
                    .a = alphas[a],
                };
            }
        }
    }
};
