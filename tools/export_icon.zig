//! Writes `src/ui/icon.zig`'s art out as the PNG the README shows, so the
//! image and the window's icon cannot drift apart: `zig build icon`
//! regenerates it. Nearest-neighbour scaling only — the art is its pixels.

const std = @import("std");
const icon = @import("icon");

const rl = @cImport(@cInclude("raylib.h"));

const scale = 8;
const out_path = "assets/icon.png";

const big = icon.size * scale;

pub fn main() !void {
    var px: [icon.size * icon.size]u32 = undefined;
    icon.pixels(&px);

    // Scaled here rather than by `ImageResizeNN`, which frees the buffer it
    // is handed — and this one is not raylib's to free.
    var out: [big * big]u32 = undefined;
    for (0..big) |y| {
        for (0..big) |x| out[y * big + x] = px[y / scale * icon.size + x / scale];
    }
    const image = rl.Image{
        .data = &out,
        .width = big,
        .height = big,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    if (!rl.ExportImage(image, out_path)) return error.ExportFailed;
}
