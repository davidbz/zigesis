//! The idle screen (DESIGN.md §5.2): a CRT tuned to a dead channel.
//!
//! Fills a small RGBA texture the frontend stretches over the window, so the
//! per-frame cost is 19200 pixels however big the window is. No raylib here
//! either: this is pixels in an array, like the VDP's.

const std = @import("std");

/// Deliberately tiny — snow has no detail to lose, and this is what keeps an
/// idle window off the CPU.
pub const width = 160;
pub const height = 120;

/// Rows are scaled by a slow sine-ish ramp so the noise has faint horizontal
/// banding rather than being uniform static.
const band_depth = 24;
/// The rolling bar: a brighter, slightly desaturated stripe drifting upward,
/// the way an untuned analogue picture rolls.
const bar_rows = 14;
const bar_lift = 40;

pub const Snow = struct {
    rng: std.Random.DefaultPrng = .init(0x5E6A_10DE),
    bar: u32 = 0,

    pub fn step(s: *Snow, px: *[width * height]u32) void {
        s.bar = (s.bar + 1) % (height + bar_rows);
        const r = s.rng.random();
        for (0..height) |y| {
            const band: i32 = @intCast((y * band_depth / height) & (band_depth - 1));
            const in_bar = y + bar_rows > s.bar and y < s.bar + bar_rows;
            const lift: i32 = band - band_depth / 2 + @as(i32, if (in_bar) bar_lift else 0);
            var x: usize = 0;
            while (x < width) : (x += 8) {
                // One 64-bit draw is eight pixels of 8-bit noise.
                var bits = r.int(u64);
                for (0..8) |i| {
                    const v: u8 = @intCast(std.math.clamp(@as(i32, @intCast(bits & 0xFF)) + lift, 0, 255));
                    px[y * width + x + i] = 0xFF00_0000 | @as(u32, v) * 0x0001_0101;
                    bits >>= 8;
                }
            }
        }
    }
};

test "the snow covers the buffer and moves" {
    var s = Snow{};
    var px: [width * height]u32 = @splat(0);
    s.step(&px);
    const first = px;
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFF00_0000), p & 0xFF00_0000);
    s.step(&px);
    try std.testing.expect(!std.mem.eql(u32, &first, &px));
}
