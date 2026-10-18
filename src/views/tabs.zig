const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:tabs";

const chart_labels = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };
const chart_data = [_][]const i64{
    &.{ 42, 55, 38, 70, 61, 80 }, // revenue
    &.{ 12, 19, 15, 27, 24, 33 }, // users
    &.{ 3, 1, 4, 1, 5, 9 }, // errors
};
pub const tab_keys = [_][]const u8{ "revenue", "users", "errors" };
const faq_sections = [_][]const u8{
    "Nothing is persisted; refreshing remounts the view fresh.",
    "Yes - the registry holds disconnected counter state for five minutes.",
    "Each region is a slot in the render tree; unchanged slots never patch.",
};
const section_keys = [_][]const u8{ "persistence", "recovery", "diffing" };
const section_titles = [_][]const u8{
    "Is anything persisted?",
    "Does my counter survive a reconnect?",
    "Why is patching so granular?",
};

pub const State = struct {
    active: usize = 0,
    open: [3]bool = .{ true, false, false },
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active_tree: usize = 0,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .arenas = .{
            std.heap.ArenaAllocator.init(allocator),
            std.heap.ArenaAllocator.init(allocator),
        } };
    }

    pub fn deinit(self: *State) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }
};

fn renderChartTree(a: std.mem.Allocator, values: []const i64) ![]view.Segment {
    const rows = try a.alloc(view.Segment, values.len);
    for (values, 0..) |v, i| {
        const fill = try a.alloc(view.Segment, 3);
        fill[0] = .text("<span class=\"chart-fill\">");
        fill[1] = .{ .dynamic = .{ .int = v } };
        fill[2] = .text("</span>");
        const row = try a.alloc(view.Segment, 5);
        row[0] = .text("<div class=\"chart-row\"><span class=\"chart-label\">");
        row[1] = .{ .dynamic = .{ .string = chart_labels[i] } };
        row[2] = .text("</span><span class=\"chart-bar\">");
        row[3] = .{ .children = fill };
        row[4] = .text("</span></div>");
        rows[i] = .{ .children = row };
    }
    const tree = try a.alloc(view.Segment, 3);
    tree[0] = .text("<div class=\"chart\" id=\"chart\">");
    tree[1] = .{ .children = rows };
    tree[2] = .text("</div>");
    return tree;
}

fn sectionContent(a: std.mem.Allocator, i: usize) ![]const view.Segment {
    const content = try a.alloc(view.Segment, 3);
    content[0] = .text("<p>");
    content[1] = .{ .dynamic = .{ .string = faq_sections[i] } };
    content[2] = .text("</p>");
    return content;
}

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mountTabs(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "switch_tab")) {
        return switchTab(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "toggle_section")) {
        return toggleSection(h, aa, env);
    }
    return h.sendErr(aa, env, "unknown_event");
}

fn mountTabs(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    _ = try h.ensure("tabs", State, State.init);
    const tree = try renderTabsView(
        h,
    );
    log.info("mounted {s}", .{topic});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "render",
        .payload = try view.treeToValue(aa, tree),
        .ref = env.ref,
    });
}

fn renderTabsView(h: *Handler) ![]const view.Segment {
    const t = h.tabs().?;
    const a = t.arenas[1 - t.active_tree].allocator();
    _ = t.arenas[1 - t.active_tree].reset(.retain_capacity);
    t.active_tree = 1 - t.active_tree;

    const chart = try renderChartTree(a, chart_data[t.active]);

    var tabs_list: std.ArrayListUnmanaged(view.Tabs.Tab) = .empty;
    for (tab_keys) |key| {
        const content = try a.alloc(view.Segment, 3);
        content[0] = .text("<h3>");
        content[1] = .{ .dynamic = .{ .string = key } };
        content[2] = .{ .children = chart };
        try tabs_list.append(a, .{
            .key = key,
            .label = key,
            .content = content,
        });
    }

    var sections: std.ArrayListUnmanaged(view.Accordion.Section) = .empty;
    for (0..3) |i| {
        try sections.append(a, .{
            .key = section_keys[i],
            .title = section_titles[i],
            .content = try sectionContent(a, i),
        });
    }
    var open_list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (t.open, 0..) |is_open, i| {
        if (is_open) try open_list.append(a, section_keys[i]);
    }

    const body = try a.alloc(view.Segment, 2);
    body[0] = .{ .children = try view.Tabs.render(a, .{
        .id = "demo",
        .tabs = tabs_list.items,
        .active = tab_keys[t.active],
    }) };
    body[1] = .{ .children = try view.Accordion.render(a, .{
        .id = "faq",
        .sections = sections.items,
        .open = open_list.items,
    }) };

    t.trees[t.active_tree] = body;
    return body;
}

fn switchTab(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const t = h.tabs() orelse return h.sendErr(aa, env, "not_joined");
    const value = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    for (tab_keys, 0..) |key, i| {
        if (std.mem.eql(u8, key, value)) {
            t.active = i;
            log.info("tab -> {s}", .{key});
            return pushTabsUpdate(h, aa, env.ref);
        }
    }
    return h.sendErr(aa, env, "unknown_tab");
}

fn toggleSection(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const t = h.tabs() orelse return h.sendErr(aa, env, "not_joined");
    const value = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    for (section_keys, 0..) |key, i| {
        if (std.mem.eql(u8, key, value)) {
            t.open[i] = !t.open[i];
            log.info("section {s} -> {s}", .{ key, if (t.open[i]) "open" else "closed" });
            return pushTabsUpdate(h, aa, env.ref);
        }
    }
    return h.sendErr(aa, env, "unknown_section");
}

fn pushTabsUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const t = h.tabs().?;
    const previous = t.trees[t.active_tree];
    const current = try renderTabsView(
        h,
    );
    var patches = try view.diff(aa, previous, current);
    defer patches.deinit();
    log.info("tabs: {d} patch(es)", .{patches.count()});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "patch",
        .payload = try patches.toValue(aa),
        .ref = ref,
    });
}
