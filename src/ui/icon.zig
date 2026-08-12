//! The app's face: a CRT tuned to a dead channel, which is the same joke the
//! idle screen tells. One character per pixel, so the art reads in a diff and
//! there is no binary asset to load at startup — `main.zig` hands it to
//! `SetWindowIcon` and `tools/export_icon.zig` writes it out as the PNG the
//! README shows. No raylib here either.

const std = @import("std");

pub const size = 32;

/// `.` transparent, `#` outline, `B` cabinet, `H` speaker grille, `A`
/// antenna, `S`/`s`/`W` the three greys of the static, `O` Zig orange, `R`
/// the power light.
pub const art = [size][]const u8{
    "................................",
    ".........O............O.........",
    "..........A..........A..........",
    "...........A........A...........",
    "............A......A............",
    "............A......A............",
    ".............A....A.............",
    "..............A..A..............",
    "..############################..",
    ".#BBBBBBBBBBBBBBBBBBBBBBBBBBBB#.",
    ".#B#####################BBBBBB#.",
    ".#B#SSSSSSSSssSSSsssWss#BBBBBB#.",
    ".#B#sSSWsssSSSSSSSSssss#BBBBBB#.",
    ".#B#SSSSWSSWSSSWSssssSS#BOOOBB#.",
    ".#B#SSSsSSSSssssSSWssss#BO#OBB#.",
    ".#B#SSSSWSSSSSSSSSsssSS#BOOOBB#.",
    ".#B#SSSSSSSSssWSSSSssss#BBBBBB#.",
    ".#B#sssssWsssSSSSSSSSSS#BBBBBB#.",
    ".#B#WWSSSsSSsSSSSSSSSSS#BOOOBB#.",
    ".#B#WWsssSSsSSSSSSssssS#BO#OBB#.",
    ".#B#WWSWsssSsSWWsssWsss#BOOOBB#.",
    ".#B#SSSSSWSSSSSSssSSsss#BBBBBB#.",
    ".#B#SSSSSSSssWSSSSSsssS#B####B#.",
    ".#B#WsssssssssSSsssssss#BHHHHB#.",
    ".#B#SssSSsSSWssssSsSSss#B####B#.",
    ".#B#SSSSSSSSSSSSSSSSSWW#BHHHHB#.",
    ".#B#SSSSSSssSSSSSssSSSW#B####B#.",
    ".#B#####################BBRBBB#.",
    ".#BBBBBBBBBBBBBBBBBBBBBBBBBBBB#.",
    "..############################..",
    "....####................####....",
    "....####................####....",
};

/// RGBA in memory order, which is a little-endian u32 backwards.
fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return a << 24 | b << 16 | g << 8 | r;
}

fn color(ch: u8) u32 {
    return switch (ch) {
        '.' => 0,
        '#' => rgba(18, 18, 22, 255),
        'B' => rgba(46, 46, 54, 255),
        'H' => rgba(74, 74, 86, 255),
        'A' => rgba(150, 150, 160, 255),
        'S' => rgba(26, 26, 32, 255),
        's' => rgba(120, 120, 128, 255),
        'W' => rgba(235, 235, 240, 255),
        'O' => rgba(247, 164, 29, 255),
        'R' => rgba(224, 48, 48, 255),
        else => unreachable,
    };
}

pub fn pixels(out: *[size * size]u32) void {
    for (art, 0..) |row, y| {
        for (row, 0..) |ch, x| out[y * size + x] = color(ch);
    }
}

test "the art is a square grid painted in known colours" {
    var px: [size * size]u32 = undefined;
    for (art) |row| try std.testing.expectEqual(size, row.len);
    pixels(&px); // an unlisted character trips `unreachable` here
    try std.testing.expectEqual(@as(u32, 0), px[0]); // corners are transparent
    try std.testing.expectEqual(color('B'), px[size * 9 + 16]); // the cabinet is not
}
