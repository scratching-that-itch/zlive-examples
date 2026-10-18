//! Renders the app's page templates at build time with zlive's layout engine.
//!
//! Pages are source templates — a layout plus blocks — but the server's page
//! table is `comptime` and embeds each page's bytes in its handler. So the
//! app's build runs this tool once per page (see `build.zig`), and the output
//! is copied to `src/pages_rendered/<name>`, which `pages.zig` embeds with
//! `@embedFile`. The binary is still self-contained, the server still serves
//! static bytes, and template mistakes fail `zig build` with a file and line
//! instead of producing a broken page.
//!
//! The engine is the framework's (`zlive.layout`); this tool only names the
//! app's sources and supplies them to it.
//!
//!     render-pages <entry.html> <output.html>

const std = @import("std");
const zlive = @import("zlive");
const layout = zlive.layout;
const manifest = @import("page_manifest.zig");

const Source = struct { name: []const u8, source: []const u8 };

/// Every template, by the name `extends`/`include`/`render` use.
const sources = [_]Source{
    .{ .name = "base.html", .source = @embedFile("templates/base.html") },
    .{ .name = "app.html", .source = @embedFile("templates/app.html") },
    .{ .name = "floating.html", .source = @embedFile("templates/floating.html") },
    .{ .name = "index.html", .source = @embedFile("pages/index.html") },
    .{ .name = "counter.html", .source = @embedFile("pages/counter.html") },
    .{ .name = "table.html", .source = @embedFile("pages/table.html") },
    .{ .name = "form.html", .source = @embedFile("pages/form.html") },
    .{ .name = "tabs.html", .source = @embedFile("pages/tabs.html") },
    .{ .name = "countries.html", .source = @embedFile("pages/countries.html") },
    .{ .name = "room.html", .source = @embedFile("pages/room.html") },
    .{ .name = "sidebar.html", .source = @embedFile("pages/sidebar.html") },
    .{ .name = "themes.html", .source = @embedFile("pages/themes.html") },
    .{ .name = "test-morph.html", .source = @embedFile("pages/test-morph.html") },
    .{ .name = "test-floating.html", .source = @embedFile("pages/test-floating.html") },
    .{ .name = "test-dd.html", .source = @embedFile("pages/test-dd.html") },
};

fn sourceFor(name: []const u8) ?[]const u8 {
    for (sources) |source| {
        if (std.mem.eql(u8, source.name, name)) return source.source;
    }
    return null;
}

/// Renders one page into `allocator`-owned bytes.
pub fn render(allocator: std.mem.Allocator, entry: []const u8) layout.Error![]const u8 {
    var engine = layout.Engine.init(allocator);
    for (sources) |source| try engine.add(source.name, source.source);
    return engine.render(entry);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // executable
    const entry = args.next() orelse return usage();
    const output = args.next() orelse return usage();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var engine = layout.Engine.init(arena.allocator());
    for (sources) |source| {
        engine.add(source.name, source.source) catch |err| return report(&engine, err);
    }
    const bytes = engine.render(entry) catch |err| return report(&engine, err);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = bytes });
}

fn report(engine: *const layout.Engine, err: layout.Error) anyerror {
    std.debug.print("render-pages: {s}:{d}: {s} ({t})\n", .{
        engine.diag.template,
        engine.diag.line,
        engine.diag.message,
        err,
    });
    return err;
}

fn usage() error{Usage} {
    std.debug.print("usage: render-pages <entry.html> <output.html>\n", .{});
    return error.Usage;
}

test "render-pages: every page extends a layout" {
    for (manifest.files) |name| {
        const source = sourceFor(name) orelse return error.UnknownPage;
        try std.testing.expect(std.mem.indexOf(u8, source, "{% extends") != null);
    }
}

test "render-pages: every page renders to a complete document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (manifest.files) |name| {
        const bytes = try render(arena.allocator(), name);
        try std.testing.expect(std.mem.startsWith(u8, bytes, "<!DOCTYPE html>"));
        try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, bytes, " \t\r\n"), "</html>"));
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "{%"));
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "{{"));
    }
}
