// The theme gallery: every palette shadcn ships, previewed at once, plus the
// picker that switches the page's own palette.
//
// The view is deliberately stateless. A theme is a client preference applied
// to <html> (see pages/theme.js) — the same reasoning as dark mode: it lives
// outside the Live root, so morphdom can never reset it and the server has
// nothing to own. The picker's buttons therefore call into the browser, and
// this view only renders the swatches once per join.
//
// What it proves is a CSS property, not a server one: the palettes are
// ordinary attribute blocks (`[data-base=…]`, `[data-accent=…]`), so a
// *subtree* can carry its own palette while the page keeps the default. Every
// card below is a wrapper with one of those attributes; the widget inside it
// is styled by variables that resolve against the wrapper, not the page.
//
// The theme list itself comes from the generated `themes.zig`, so the gallery
// cannot drift from the stylesheet: scripts/gen_themes.py writes both.

const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const Handler = @import("handler").Handler;

pub const topic = "view:themes";

pub const State = struct {
    /// One arena is enough: nothing diffs, so a render never has to outlive
    /// the response it was serialized into.
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
};

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (!std.mem.eql(u8, env.event, "join")) {
        return h.sendErr(aa, env, "unknown_event");
    }
    const t = try h.ensure("themes", State, State.init);
    _ = t.arena.reset(.retain_capacity);
    const tree = try render(t.arena.allocator());
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "render",
        .payload = try view.treeToValue(aa, tree),
        .ref = env.ref,
    });
}

/// The picker: one row of base colors, one of accents, and the mode toggle.
/// These are plain buttons with inline `onclick`, not `data-lv-click`: the
/// theme is client state, so no roundtrip is involved.
fn picker(a: std.mem.Allocator) ![]const view.Segment {
    var out: std.ArrayListUnmanaged(view.Segment) = .empty;
    try out.append(a, .text("<div class=\"tm-picker\"><p class=\"tm-pick-label\">Base color</p>" ++
        "<p class=\"tm-row tm-bases\">" ++
        "<button type=\"button\" class=\"btn\" data-variant=\"outline\" data-size=\"sm\" " ++
        "data-tm-base=\"\" onclick=\"zcTheme.setBase('')\">default</button>"));
    for (view.themes.bases) |theme| {
        try out.appendSlice(a, &.{
            .text("<button type=\"button\" class=\"btn\" data-variant=\"outline\" data-size=\"sm\" " ++
                "data-tm-base=\""),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.name } });
        try out.appendSlice(a, &.{
            .text("\" onclick=\"zcTheme.setBase('"),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.name } });
        try out.appendSlice(a, &.{
            .text("')\">"),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.title } });
        try out.append(a, .text("</button>"));
    }
    try out.append(a, .text("</p><p class=\"tm-pick-label\">Accent</p>" ++
        "<p class=\"tm-row tm-accents\">" ++
        "<button type=\"button\" class=\"btn\" data-variant=\"outline\" data-size=\"sm\" " ++
        "data-tm-accent=\"\" onclick=\"zcTheme.setAccent('')\">none</button>"));
    for (view.themes.accents) |theme| {
        try out.appendSlice(a, &.{
            .text("<button type=\"button\" class=\"btn\" data-variant=\"outline\" data-size=\"sm\" " ++
                "data-tm-accent=\""),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.name } });
        try out.appendSlice(a, &.{
            .text("\" onclick=\"zcTheme.setAccent('"),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.name } });
        try out.appendSlice(a, &.{
            .text("')\">"),
        });
        try out.append(a, .{ .dynamic = .{ .string = theme.title } });
        try out.append(a, .text("</button>"));
    }
    try out.append(a, .text("</p><p class=\"tm-row\">" ++
        "<button type=\"button\" class=\"btn\" data-variant=\"secondary\" data-size=\"sm\" " ++
        "onclick=\"zcTheme.toggle()\">light / dark</button>" ++
        "<button type=\"button\" class=\"btn\" data-variant=\"ghost\" data-size=\"sm\" " ++
        "onclick=\"zcTheme.reset()\">reset</button></p></div>"));
    return out.toOwnedSlice(a);
}

/// A card previewing one theme: the token surfaces as swatches, then real
/// components inside the same wrapper.
fn card(a: std.mem.Allocator, theme: view.themes.Theme, attr: []const u8) ![]const view.Segment {
    var out: std.ArrayListUnmanaged(view.Segment) = .empty;
    try out.appendSlice(a, &.{
        .text("<div class=\"tm-card\" "),
        .text(attr),
        .text("=\""),
    });
    try out.append(a, .{ .dynamic = .{ .string = theme.name } });
    try out.appendSlice(a, &.{
        .text("\"><p class=\"tm-name\">"),
    });
    try out.append(a, .{ .dynamic = .{ .string = theme.title } });
    try out.appendSlice(a, &.{
        .text("</p><div class=\"tm-row\">" ++
            "<span class=\"tm-sw tm-bg\" title=\"--background\"></span>" ++
            "<span class=\"tm-sw tm-card\" title=\"--card\"></span>" ++
            "<span class=\"tm-sw tm-primary\" title=\"--primary\"></span>" ++
            "<span class=\"tm-sw tm-secondary\" title=\"--secondary\"></span>" ++
            "<span class=\"tm-sw tm-muted\" title=\"--muted\"></span>" ++
            "<span class=\"tm-sw tm-accent\" title=\"--accent\"></span>" ++
            "<span class=\"tm-sw tm-border\" title=\"--border\"></span>" ++
            "<span class=\"tm-sw tm-ring\" title=\"--ring\"></span>" ++
            "<span class=\"tm-sw tm-destructive\" title=\"--destructive\"></span>" ++
            "</div><div class=\"tm-charts\">" ++
            "<span class=\"tm-sw tm-chart-1\"></span><span class=\"tm-sw tm-chart-2\"></span>" ++
            "<span class=\"tm-sw tm-chart-3\"></span><span class=\"tm-sw tm-chart-4\"></span>" ++
            "<span class=\"tm-sw tm-chart-5\"></span></div>" ++
            "<div class=\"tm-row tm-buttons\">" ++
            "<button type=\"button\" class=\"btn\" data-variant=\"default\" data-size=\"sm\">primary</button>" ++
            "<button type=\"button\" class=\"btn\" data-variant=\"outline\" data-size=\"sm\">outline</button>" ++
            "<button type=\"button\" class=\"btn\" data-variant=\"secondary\" data-size=\"sm\">secondary</button>" ++
            "<button type=\"button\" class=\"btn\" data-variant=\"ghost\" data-size=\"sm\">ghost</button>" ++
            "<button type=\"button\" class=\"btn\" data-variant=\"destructive\" data-size=\"sm\">delete</button>" ++
            "</div><div class=\"tm-sidebar\"><span class=\"tm-side-name\">sidebar</span>" ++
            "<span class=\"tm-side-row tm-side-active\">active row</span>" ++
            "<span class=\"tm-side-row\">plain row</span></div></div>"),
    });
    return out.toOwnedSlice(a);
}

fn gallery(a: std.mem.Allocator, themes: []const view.themes.Theme, attr: []const u8) ![]const view.Segment {
    var cards: std.ArrayListUnmanaged(view.Segment) = .empty;
    for (themes) |theme| {
        try cards.append(a, .{ .children = try card(a, theme, attr) });
    }
    const wrap = try a.alloc(view.Segment, 3);
    wrap[0] = .text("<div class=\"tm-grid\">");
    wrap[1] = .{ .children = try cards.toOwnedSlice(a) };
    wrap[2] = .text("</div>");
    return wrap;
}

fn render(a: std.mem.Allocator) ![]const view.Segment {
    const tree = try a.alloc(view.Segment, 11);
    tree[0] = .text("<h1>Themes</h1><p class=\"tm-intro\">All " ++
        "themes shadcn ships, rendered from the same generated list the " ++
        "stylesheet is built from: ");
    tree[1] = .{ .dynamic = .{ .int = @intCast(view.themes.bases.len) } };
    tree[2] = .text(" base colors (a complete token set) and ");
    tree[3] = .{ .dynamic = .{ .int = @intCast(view.themes.accents.len) } };
    tree[4] = .text(" accent themes (which override primary, secondary, the chart " ++
        "ramp and sidebar-primary, and layer on whichever base is active). " ++
        "Each card below is a plain wrapper with <code>data-base</code> or " ++
        "<code>data-accent</code> on it, so these palettes compose per subtree " ++
        "— the page around them never changes.</p>");
    tree[5] = .{ .children = try picker(a) };
    tree[6] = .text("<h2>Base colors</h2>");
    tree[7] = .{ .children = try gallery(a, &view.themes.bases, "data-base") };
    tree[8] = .text("<h2>Accents</h2><p class=\"tm-intro\">An accent is shown on the " ++
        "default (neutral) base — pick a base above and this page switches to it, " ++
        "while the cards keep previewing neutral + accent.</p>");
    tree[9] = .{ .children = try gallery(a, &view.themes.accents, "data-accent") };
    tree[10] = .text("");
    return tree;
}

test "the gallery renders a card per theme, with the palette on a wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try render(arena.allocator());
    const html = try view.flattenHtml(arena.allocator(), tree);
    for (view.themes.all) |theme| {
        try std.testing.expect(std.mem.indexOf(u8, html, theme.title) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, html, "data-base=\"zinc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-accent=\"blue\"") != null);
    // the picker is client-side: no server events on this page
    try std.testing.expect(std.mem.indexOf(u8, html, "data-lv-click") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "zcTheme.setBase('zinc')") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "zcTheme.setAccent('')") != null);
}
