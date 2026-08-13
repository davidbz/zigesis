//! Options persistence: a plain `key = value` text file (DESIGN.md §8), read
//! at startup and rewritten whenever the menu changes something.
//!
//! Unknown keys are ignored and out-of-range values are clamped, so a
//! hand-edited file can be wrong without being fatal. A file whose `version`
//! is not ours is ignored whole: this is settings, and defaults are a fine
//! answer.

const std = @import("std");
const input = @import("input");

pub const version = 1;

pub const min_scale = 1;
pub const max_scale = 4;

/// Which timing the machine runs at. `auto` reads the cartridge header,
/// which is what a user wants until it guesses wrong on some import.
pub const Region = enum { auto, ntsc, pal };

/// What is plugged into a controller port. Three buttons is the default
/// because a six-button pad is not a superset: its sixth read hands a game
/// every direction at once, and one that only knows the three-button pad reads
/// that as the stick being pushed four ways.
pub const PadType = enum { three, six };

pub const Config = struct {
    scale: u8 = 3,
    fullscreen: bool = false,
    region: Region = .auto,
    audio: bool = true,
    volume: u8 = 100,
    pads: [2]PadType = @splat(.three),
    keys: input.Bindings = input.defaults,

    pub fn parse(text: []const u8) Config {
        var cfg = Config{};
        var seen_version = false;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "version")) {
                if (!std.mem.eql(u8, val, std.fmt.comptimePrint("{d}", .{version}))) return .{};
                seen_version = true;
            } else if (std.mem.eql(u8, key, "scale")) {
                cfg.scale = std.math.clamp(parseInt(u8, val) orelse cfg.scale, min_scale, max_scale);
            } else if (std.mem.eql(u8, key, "fullscreen")) {
                cfg.fullscreen = parseBool(val) orelse cfg.fullscreen;
            } else if (std.mem.eql(u8, key, "region")) {
                cfg.region = std.meta.stringToEnum(Region, val) orelse cfg.region;
            } else if (std.mem.eql(u8, key, "audio")) {
                cfg.audio = parseBool(val) orelse cfg.audio;
            } else if (std.mem.eql(u8, key, "volume")) {
                cfg.volume = @min(100, parseInt(u8, val) orelse cfg.volume);
            } else if (std.mem.eql(u8, key, "pad1")) {
                cfg.pads[0] = std.meta.stringToEnum(PadType, val) orelse cfg.pads[0];
            } else if (std.mem.eql(u8, key, "pad2")) {
                cfg.pads[1] = std.meta.stringToEnum(PadType, val) orelse cfg.pads[1];
            } else if (std.mem.startsWith(u8, key, "key.")) {
                const action = std.meta.stringToEnum(input.Action, key["key.".len..]) orelse continue;
                cfg.keys[@intFromEnum(action)] = input.keyCode(val) orelse continue;
            }
        }
        // A file without a version line is from nowhere we know.
        return if (seen_version) cfg else .{};
    }

    pub fn write(cfg: Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("# zigesis options\nversion = {d}\n", .{version});
        try w.print("scale = {d}\n", .{cfg.scale});
        try w.print("fullscreen = {}\n", .{cfg.fullscreen});
        try w.print("region = {s}\n", .{@tagName(cfg.region)});
        try w.print("audio = {}\n", .{cfg.audio});
        try w.print("volume = {d}\n", .{cfg.volume});
        try w.print("pad1 = {s}\npad2 = {s}\n", .{ @tagName(cfg.pads[0]), @tagName(cfg.pads[1]) });
        var buf: [input.max_key_name]u8 = undefined;
        for (std.enums.values(input.Action)) |action| {
            const key = cfg.keys[@intFromEnum(action)];
            try w.print("key.{s} = {s}\n", .{ @tagName(action), input.keyName(key, &buf) });
        }
    }
};

fn parseInt(comptime T: type, val: []const u8) ?T {
    return std.fmt.parseInt(T, val, 10) catch null;
}

fn parseBool(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

test "a written config parses back identical" {
    var cfg = Config{ .scale = 2, .fullscreen = true, .region = .pal, .audio = false, .volume = 42, .pads = .{ .six, .three } };
    cfg.keys[@intFromEnum(input.Action.start)] = 'Q';
    cfg.keys[@intFromEnum(input.Action.menu)] = 348; // unnamed: goes out as a number

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.write(&w);
    try std.testing.expectEqual(cfg, Config.parse(w.buffered()));
}

test "junk and out-of-range values fall back instead of failing" {
    const cfg = Config.parse(
        \\# comment
        \\version = 1
        \\scale = 99
        \\volume = not-a-number
        \\region = klingon
        \\nonsense = 3
        \\key.up = F1
    );
    try std.testing.expectEqual(@as(u8, max_scale), cfg.scale);
    try std.testing.expectEqual(@as(u8, 100), cfg.volume);
    try std.testing.expectEqual(Region.auto, cfg.region);
    try std.testing.expectEqual(input.keyCode("F1").?, cfg.keys[@intFromEnum(input.Action.up)]);
}

test "a foreign or unversioned file is ignored whole" {
    try std.testing.expectEqual(Config{}, Config.parse("version = 99\nscale = 1\n"));
    try std.testing.expectEqual(Config{}, Config.parse("scale = 1\n"));
}
