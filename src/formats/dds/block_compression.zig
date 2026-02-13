const color = @import("../../color.zig");
const std = @import("std");
const bc7dat: BC7Data = @import("bc7_data.zon");

const BC7Data = struct {
    twoSubsets: struct {
        partitions: [64][16]u2,
        anchorIdxs: [64]u4,
    },
    threeSubsets: struct {
        partitions: [64][16]u2,
        anchorIdxs: [2][64]u4,
    },
    ipolTables: struct {
        twoBit: [4]u7,
        threeBit: [8]u7,
        fourBit: [16]u7,
    },
    // modeInfo: struct {
    //     mode0: ModeInfo,
    //     mode1: ModeInfo,
    //     mode2: ModeInfo,
    //     mode3: ModeInfo,
    //     mode4: ModeInfo,
    //     mode5: ModeInfo,
    //     mode6: ModeInfo,
    //     mode7: ModeInfo,
    // },
};

// const ModeInfo = struct {
//     id: u8,
//     numEndpointPairs: u8,
//     partitionBitCnt: ?u8,
//     rotationBitCnt: ?u8,
//     hasIdxSelection: bool,
//     colorBitCnt: u8,
//     alphaBitCnt: ?u8,
//     pBitExists: bool,
//     pBitIsShared: bool,
//     idxBitCnt: u8,
//     idxBitCnt2: ?u8,
// };

fn bitIndex(Source: type, Dest: type, value: Source, index: usize) Dest {
    const nbits = @typeInfo(Dest).int.bits;
    const shift = index * nbits;
    return @truncate(value >> @intCast(shift));
}

fn interpolate(T: type, from: T, to: T, index: usize, steps: usize) T {
    const left = (steps - index) * @as(usize, from);
    const right = index * @as(usize, to);
    return @intCast((left + right + (steps / 2)) / steps);
}

fn combine(S: type, channel: S, T: type, p: T) u8 {
    if (T != u0 and T != u1) @compileError("bad T passed to combine func");
    if (S == u8) @compileError("bad S passed to combine func");

    var result: u8 = channel;
    var pwidth: u1 = 0;
    if (T != u0) {
        result <<= 1;
        result |= p;
        pwidth = 1;
        if (S == u7) return result;
    }

    const nBitsToFill: u3 = @intCast(8 - @typeInfo(S).int.bits - pwidth);
    result <<= nBitsToFill;

    const highShift: u3 = @intCast(@as(u4, 8) - nBitsToFill);
    const mask = (@as(u8, 1) << nBitsToFill) - 1;
    const maskShifted = mask << highShift;
    const highBits = result & maskShifted;
    const highBitsShifted = highBits >> highShift;
    result |= highBitsShifted;

    return result;
}

fn decodeEndpoints(comptime nEps: usize, EpDataType: type, EpEntryType: type, epDatRaw: EpDataType, PType: type, p: [nEps]PType) [nEps][2]u8 {
    var result: [nEps][2]u8 = undefined;

    for (0..(nEps / 2)) |i| {
        const start = bitIndex(EpDataType, EpEntryType, epDatRaw, i * 2);
        const end = bitIndex(EpDataType, EpEntryType, epDatRaw, i * 2 + 1);
        result[i] = .{
            combine(EpEntryType, start, PType, p[i * 2]),
            combine(EpEntryType, end, PType, p[i * 2 + 1]),
        };
    }

    return result;
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
                    .a = interpolate(u8, 0, 255, a, 15),
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

pub const BC7Block = struct {
    const Mode0 = packed struct(u128) {
        mode: u1,
        partitionId: u4,
        endpointsR: u24,
        endpointsG: u24,
        endpointsB: u24,
        ps: u6,
        indexData: u45,

        pub fn decode(self: Mode0) [16]color.Rgba32 {
            var endpointsRealR: [6]u8 = undefined;
            var endpointsRealG: [6]u8 = undefined;
            var endpointsRealB: [6]u8 = undefined;
            for (0..6) |i| {
                const epDatR: u4 = bitIndex(u24, u4, self.endpointsR, i);
                const epDatG: u4 = bitIndex(u24, u4, self.endpointsG, i);
                const epDatB: u4 = bitIndex(u24, u4, self.endpointsB, i);
                const pValR: u1 = bitIndex(u6, u1, self.ps, i);
                const pValG: u1 = bitIndex(u6, u1, self.ps, i);
                const pValB: u1 = bitIndex(u6, u1, self.ps, i);
                endpointsRealR[i] = combine(u4, epDatR, u1, pValR);
                endpointsRealG[i] = combine(u4, epDatG, u1, pValG);
                endpointsRealB[i] = combine(u4, epDatB, u1, pValB);
            }

            const partitionLookup = bc7dat.threeSubsets.partitions[self.partitionId];

            var idxs: [16]u3 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const pixelPartition = partitionLookup[i];
                const anchor = if (pixelPartition == 0) 0 else bc7dat.threeSubsets.anchorIdxs[pixelPartition - 1][self.partitionId];
                const nBits: u2 = if (anchor == i) 2 else 3;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const idx1: usize = @as(usize, partitionLookup[i]) * 2;
                const idx2: usize = @as(usize, partitionLookup[i]) * 2 + 1;
                const ipol = bc7dat.ipolTables.threeBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[idx1], endpointsRealR[idx2], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[idx1], endpointsRealG[idx2], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[idx1], endpointsRealB[idx2], ipol, 64),
                    .a = 255,
                };
            }
            return result;
        }
    };

    const Mode1 = packed struct(u128) {
        mode: u2,
        partitionId: u6,
        endpointsR: u24,
        endpointsG: u24,
        endpointsB: u24,
        ps: u2,
        indexData: u46,

        pub fn decode(self: Mode1) [16]color.Rgba32 {
            // std.debug.print("1 = {b}\n", .{self.mode});
            var endpointsRealR: [4]u8 = undefined;
            var endpointsRealG: [4]u8 = undefined;
            var endpointsRealB: [4]u8 = undefined;
            const pValA: u1 = bitIndex(u2, u1, self.ps, 0);
            const pValB: u1 = bitIndex(u2, u1, self.ps, 1);
            for (0..4) |i| {
                const epDatR: u6 = bitIndex(u24, u6, self.endpointsR, i);
                const epDatG: u6 = bitIndex(u24, u6, self.endpointsG, i);
                const epDatB: u6 = bitIndex(u24, u6, self.endpointsB, i);
                endpointsRealR[i] = combine(u6, epDatR, u1, if (i % 2 == 0) pValA else pValB);
                endpointsRealG[i] = combine(u6, epDatG, u1, if (i % 2 == 0) pValA else pValB);
                endpointsRealB[i] = combine(u6, epDatB, u1, if (i % 2 == 0) pValA else pValB);
            }

            const partitionLookup = bc7dat.twoSubsets.partitions[self.partitionId];

            var idxs: [16]u3 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const pixelPartition = partitionLookup[i];
                const anchor = if (pixelPartition == 0) 0 else bc7dat.twoSubsets.anchorIdxs[self.partitionId];
                const nBits: u2 = if (anchor == i) 2 else 3;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const idx1: usize = @as(usize, partitionLookup[i]) * 2;
                const idx2: usize = @as(usize, partitionLookup[i]) * 2 + 1;
                const ipol = bc7dat.ipolTables.threeBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[idx1], endpointsRealR[idx2], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[idx1], endpointsRealG[idx2], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[idx1], endpointsRealB[idx2], ipol, 64),
                    .a = 255,
                };
            }
            return result;
        }
    };

    const Mode2 = packed struct(u128) {
        mode: u3,
        partitionId: u6,
        endpointsR: u30,
        endpointsG: u30,
        endpointsB: u30,
        indexData: u29,

        pub fn decode(self: Mode2) [16]color.Rgba32 {
            // std.debug.print("2 = {b}\n", .{self.mode});
            var endpointsRealR: [6]u8 = undefined;
            var endpointsRealG: [6]u8 = undefined;
            var endpointsRealB: [6]u8 = undefined;
            for (0..6) |i| {
                endpointsRealR[i] = combine(u5, bitIndex(u30, u5, self.endpointsR, i), u0, 0);
                endpointsRealG[i] = combine(u5, bitIndex(u30, u5, self.endpointsG, i), u0, 0);
                endpointsRealB[i] = combine(u5, bitIndex(u30, u5, self.endpointsB, i), u0, 0);
            }

            const partitionLookup = bc7dat.threeSubsets.partitions[self.partitionId];

            var idxs: [16]u2 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const pixelPartition = partitionLookup[i];
                const anchor = if (pixelPartition == 0) 0 else bc7dat.threeSubsets.anchorIdxs[pixelPartition - 1][self.partitionId];
                const nBits: u2 = if (anchor == i) 1 else 2;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const idx1: usize = @as(usize, partitionLookup[i]) * 2;
                const idx2: usize = @as(usize, partitionLookup[i]) * 2 + 1;
                const ipol = bc7dat.ipolTables.twoBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[idx1], endpointsRealR[idx2], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[idx1], endpointsRealG[idx2], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[idx1], endpointsRealB[idx2], ipol, 64),
                    .a = 255,
                };
            }
            return result;
        }
    };

    const Mode3 = packed struct(u128) {
        // 2 subsets
        mode: u4,
        partitionId: u6,
        endpointsR: u28,
        endpointsG: u28,
        endpointsB: u28,
        ps: u4,
        indexData: u30,

        pub fn decode(self: Mode3) [16]color.Rgba32 {
            // std.debug.print("3 = {b}\n", .{self.mode});
            var endpointsRealR: [4]u8 = undefined;
            var endpointsRealG: [4]u8 = undefined;
            var endpointsRealB: [4]u8 = undefined;
            for (0..4) |i| {
                const epDatR: u7 = bitIndex(u28, u7, self.endpointsR, i);
                const epDatG: u7 = bitIndex(u28, u7, self.endpointsG, i);
                const epDatB: u7 = bitIndex(u28, u7, self.endpointsB, i);
                const pVal: u1 = bitIndex(u4, u1, self.ps, i);
                endpointsRealR[i] = combine(u7, epDatR, u1, pVal);
                endpointsRealG[i] = combine(u7, epDatG, u1, pVal);
                endpointsRealB[i] = combine(u7, epDatB, u1, pVal);
            }

            const partitionLookup = bc7dat.twoSubsets.partitions[self.partitionId];

            var idxs: [16]u2 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const pixelPartition = partitionLookup[i];
                const anchor = if (pixelPartition == 0) 0 else bc7dat.twoSubsets.anchorIdxs[self.partitionId];
                const nBits: u2 = if (anchor == i) 1 else 2;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const idx1: usize = @as(usize, partitionLookup[i]) * 2;
                const idx2: usize = @as(usize, partitionLookup[i]) * 2 + 1;
                const ipol = bc7dat.ipolTables.twoBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[idx1], endpointsRealR[idx2], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[idx1], endpointsRealG[idx2], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[idx1], endpointsRealB[idx2], ipol, 64),
                    .a = 255,
                };
            }
            return result;
        }
    };

    const Mode4 = packed struct(u128) {
        // 1 subset
        mode: u5,
        rotation: u2,
        idxFlipped: bool,
        endpointsR: u10,
        endpointsG: u10,
        endpointsB: u10,
        endpointsA: u12,
        indexData1: u31,
        indexData2: u47,

        pub fn decode(self: Mode4) [16]color.Rgba32 {
            // std.debug.print("4 = {b}\n", .{self.mode});
            var endpointsRealR: [2]u8 = undefined;
            var endpointsRealG: [2]u8 = undefined;
            var endpointsRealB: [2]u8 = undefined;
            var endpointsRealA: [2]u8 = undefined;
            for (0..2) |i| {
                const epDatR: u5 = bitIndex(u10, u5, self.endpointsR, i);
                const epDatG: u5 = bitIndex(u10, u5, self.endpointsG, i);
                const epDatB: u5 = bitIndex(u10, u5, self.endpointsB, i);
                const epDatA: u6 = bitIndex(u12, u6, self.endpointsA, i);
                endpointsRealR[i] = if (self.rotation == 1) combine(u6, epDatA, u0, 0) else combine(u5, epDatR, u0, 0);
                endpointsRealG[i] = if (self.rotation == 2) combine(u6, epDatA, u0, 0) else combine(u5, epDatG, u0, 0);
                endpointsRealB[i] = if (self.rotation == 3) combine(u6, epDatA, u0, 0) else combine(u5, epDatB, u0, 0);
                endpointsRealA[i] = switch (self.rotation) {
                    0 => combine(u6, epDatA, u0, 0),
                    1 => combine(u5, epDatR, u0, 0),
                    2 => combine(u5, epDatG, u0, 0),
                    3 => combine(u5, epDatB, u0, 0),
                };
            }

            var idxs1: [16]u2 = undefined;
            var idxs2: [16]u3 = undefined;
            var data1 = self.indexData1;
            var data2 = self.indexData2;

            for (0..16) |i| {
                const nBits1: u2 = if (i == 0) 1 else 2;
                const nBits2: u2 = if (i == 0) 2 else 3;
                const mask1 = (@as(u4, 1) << nBits1) - 1;
                const mask2 = (@as(u4, 1) << nBits2) - 1;
                idxs1[i] = @intCast(data1 & mask1);
                idxs2[i] = @intCast(data2 & mask2);
                data1 >>= nBits1;
                data2 >>= nBits2;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const ipolCol = if (!self.idxFlipped) bc7dat.ipolTables.twoBit[idxs1[i]] else bc7dat.ipolTables.threeBit[idxs2[i]];
                const ipolAlpha = if (!self.idxFlipped) bc7dat.ipolTables.threeBit[idxs2[i]] else bc7dat.ipolTables.twoBit[idxs1[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[0], endpointsRealR[1], ipolCol, 64),
                    .g = interpolate(u8, endpointsRealG[0], endpointsRealG[1], ipolCol, 64),
                    .b = interpolate(u8, endpointsRealB[0], endpointsRealB[1], ipolCol, 64),
                    .a = interpolate(u8, endpointsRealA[0], endpointsRealA[1], ipolAlpha, 64),
                };
            }
            return result;
        }
    };

    const Mode5 = packed struct(u128) {
        // 1 subset
        mode: u6,
        rotation: u2,
        endpointsR: u14,
        endpointsG: u14,
        endpointsB: u14,
        endpointsA: u16,
        indexData1: u31,
        indexData2: u31,

        pub fn decode(self: Mode5) [16]color.Rgba32 {
            // std.debug.print("5 = {b}\n", .{self.mode});
            var endpointsRealR: [2]u8 = undefined;
            var endpointsRealG: [2]u8 = undefined;
            var endpointsRealB: [2]u8 = undefined;
            var endpointsRealA: [2]u8 = undefined;
            for (0..2) |i| {
                const epDatR: u7 = bitIndex(u14, u7, self.endpointsR, i);
                const epDatG: u7 = bitIndex(u14, u7, self.endpointsG, i);
                const epDatB: u7 = bitIndex(u14, u7, self.endpointsB, i);
                const epDatA: u8 = bitIndex(u16, u8, self.endpointsA, i);
                endpointsRealR[i] = if (self.rotation == 1) epDatA else combine(u7, epDatR, u0, 0);
                endpointsRealG[i] = if (self.rotation == 2) epDatA else combine(u7, epDatG, u0, 0);
                endpointsRealB[i] = if (self.rotation == 3) epDatA else combine(u7, epDatB, u0, 0);
                endpointsRealA[i] = switch (self.rotation) {
                    0 => epDatA,
                    1 => combine(u7, epDatR, u0, 0),
                    2 => combine(u7, epDatG, u0, 0),
                    3 => combine(u7, epDatB, u0, 0),
                };
            }

            var idxs1: [16]u2 = undefined;
            var idxs2: [16]u2 = undefined;
            var data1 = self.indexData1;
            var data2 = self.indexData2;

            for (0..16) |i| {
                const nBits: u2 = if (i == 0) 1 else 2;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs1[i] = @intCast(data1 & mask);
                idxs2[i] = @intCast(data2 & mask);
                data1 >>= nBits;
                data2 >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const ipolCol = bc7dat.ipolTables.twoBit[idxs1[i]];
                const ipolAlpha = bc7dat.ipolTables.twoBit[idxs2[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[0], endpointsRealR[1], ipolCol, 64),
                    .g = interpolate(u8, endpointsRealG[0], endpointsRealG[1], ipolCol, 64),
                    .b = interpolate(u8, endpointsRealB[0], endpointsRealB[1], ipolCol, 64),
                    .a = interpolate(u8, endpointsRealA[0], endpointsRealA[1], ipolAlpha, 64),
                };
            }
            return result;
        }
    };

    const Mode6 = packed struct(u128) {
        // 1 subset
        mode: u7,
        endpointsR: u14,
        endpointsG: u14,
        endpointsB: u14,
        endpointsA: u14,
        ps: u2,
        indexData: u63,

        pub fn decode(self: Mode6) [16]color.Rgba32 {
            // std.debug.print("6 = {b}\n", .{self.mode});
            var endpointsRealR: [2]u8 = undefined;
            var endpointsRealG: [2]u8 = undefined;
            var endpointsRealB: [2]u8 = undefined;
            var endpointsRealA: [2]u8 = undefined;
            for (0..2) |i| {
                const epDatR: u7 = bitIndex(u14, u7, self.endpointsR, i);
                const epDatG: u7 = bitIndex(u14, u7, self.endpointsG, i);
                const epDatB: u7 = bitIndex(u14, u7, self.endpointsB, i);
                const epDatA: u7 = bitIndex(u14, u7, self.endpointsA, i);
                const p: u1 = bitIndex(u2, u1, self.ps, i);
                endpointsRealR[i] = combine(u7, epDatR, u1, p);
                endpointsRealG[i] = combine(u7, epDatG, u1, p);
                endpointsRealB[i] = combine(u7, epDatB, u1, p);
                endpointsRealA[i] = combine(u7, epDatA, u1, p);
            }

            var idxs: [16]u4 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const nBits: u3 = if (i == 0) 3 else 4;
                const mask = (@as(u5, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const ipol = bc7dat.ipolTables.fourBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[0], endpointsRealR[1], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[0], endpointsRealG[1], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[0], endpointsRealB[1], ipol, 64),
                    .a = interpolate(u8, endpointsRealA[0], endpointsRealA[1], ipol, 64),
                };
            }
            return result;
        }
    };

    const Mode7 = packed struct(u128) {
        // 2 subsets
        mode: u8,
        partitionId: u6,
        endpointsR: u20,
        endpointsG: u20,
        endpointsB: u20,
        endpointsA: u20,
        ps: u4,
        indexData: u30,

        pub fn decode(self: Mode7) [16]color.Rgba32 {
            // std.debug.print("7 = {b}\n", .{self.mode});
            var endpointsRealR: [4]u8 = undefined;
            var endpointsRealG: [4]u8 = undefined;
            var endpointsRealB: [4]u8 = undefined;
            var endpointsRealA: [4]u8 = undefined;
            for (0..4) |i| {
                const epDatR: u5 = bitIndex(u20, u5, self.endpointsR, i);
                const epDatG: u5 = bitIndex(u20, u5, self.endpointsG, i);
                const epDatB: u5 = bitIndex(u20, u5, self.endpointsB, i);
                const epDatA: u5 = bitIndex(u20, u5, self.endpointsA, i);
                const pVal: u1 = bitIndex(u4, u1, self.ps, i);
                endpointsRealR[i] = combine(u5, epDatR, u1, pVal);
                endpointsRealG[i] = combine(u5, epDatG, u1, pVal);
                endpointsRealB[i] = combine(u5, epDatB, u1, pVal);
                endpointsRealA[i] = combine(u5, epDatA, u1, pVal);
            }

            const partitionLookup = bc7dat.twoSubsets.partitions[self.partitionId];

            var idxs: [16]u2 = undefined;
            var data = self.indexData;

            for (0..16) |i| {
                const pixelPartition = partitionLookup[i];
                const anchor = if (pixelPartition == 0) 0 else bc7dat.twoSubsets.anchorIdxs[self.partitionId];
                const nBits: u2 = if (anchor == i) 1 else 2;
                const mask = (@as(u4, 1) << nBits) - 1;
                idxs[i] = @intCast(data & mask);
                data >>= nBits;
            }
            var result: [16]color.Rgba32 = undefined;

            for (0..16) |i| {
                const idx1: usize = @as(usize, partitionLookup[i]) * 2;
                const idx2: usize = @as(usize, partitionLookup[i]) * 2 + 1;
                const ipol = bc7dat.ipolTables.twoBit[idxs[i]];
                result[i] = color.Rgba32{
                    .r = interpolate(u8, endpointsRealR[idx1], endpointsRealR[idx2], ipol, 64),
                    .g = interpolate(u8, endpointsRealG[idx1], endpointsRealG[idx2], ipol, 64),
                    .b = interpolate(u8, endpointsRealB[idx1], endpointsRealB[idx2], ipol, 64),
                    .a = interpolate(u8, endpointsRealA[idx1], endpointsRealA[idx2], ipol, 64),
                };
            }
            return result;
        }
    };

    pub fn decode(reader: *std.Io.Reader, pixels: color.PixelStorage, bx: usize, by: usize, width: usize) !void {
        const raw = try reader.takeInt(u128, .little);
        const result: [16]color.Rgba32 = switch (@ctz(raw)) {
            0 => @as(Mode0, @bitCast(raw)).decode(), // OK
            1 => @as(Mode1, @bitCast(raw)).decode(), // OK
            2 => @as(Mode2, @bitCast(raw)).decode(), // OK
            3 => @as(Mode3, @bitCast(raw)).decode(), // OK
            4 => @as(Mode4, @bitCast(raw)).decode(), // OK
            5 => @as(Mode5, @bitCast(raw)).decode(),
            6 => @as(Mode6, @bitCast(raw)).decode(), // OK
            7 => @as(Mode7, @bitCast(raw)).decode(), // OK
            // 0 => @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 }),
            // 1 => @splat(.{ .r = 255, .g = 0, .b = 0, .a = 255 }),
            // 2 => @splat(.{ .r = 0, .g = 0, .b = 255, .a = 255 }),
            // 3 => @splat(.{ .r = 0, .g = 255, .b = 0, .a = 255 }),
            // 4 => @splat(.{ .r = 255, .g = 0, .b = 255, .a = 255 }),
            // 5 => @splat(.{ .r = 255, .g = 255, .b = 0, .a = 255 }),
            // 6 => @splat(.{ .r = 0, .g = 255, .b = 255, .a = 255 }),
            // 7 => @splat(.{ .r = 128, .g = 128, .b = 128, .a = 255 }),
            else => return error.Unsupported,
        };

        for (0..4) |y| {
            for (0..4) |x| {
                pixels.rgba32[(by + y) * width + (bx + x)] = result[y * 4 + x];
            }
        }
    }
};
