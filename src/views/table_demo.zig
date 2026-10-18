const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:table";
pub const table_rows = 100;

const table_columns = [_]view.Table.Column{
    .{ .key = "name", .label = "Name" },
    .{ .key = "score", .label = "Score" },
    .{ .key = "actions", .label = "Actions" },
};

const sort_options = [_]view.Select.Option_{
    .{ .value = "score", .label = "by score" },
    .{ .value = "name", .label = "by name" },
};

const TableRow = struct {
    name: [24]u8 = undefined,
    name_len: usize = 0,
    score: i64,
};

pub const State = struct {
    rows: [table_rows]TableRow = undefined,
    sort_col: usize = 1,
    sort_asc: bool = true,
    /// which row's actions dropdown is open (server state), if any
    open_menu: ?usize = null,
    popover_open: bool = false,
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active: usize = 0,

    fn init(allocator: std.mem.Allocator) State {
        var t = State{
            .arenas = .{
                std.heap.ArenaAllocator.init(allocator),
                std.heap.ArenaAllocator.init(allocator),
            },
        };
        for (&t.rows, 0..) |*row, i| {
            row.name_len = (std.fmt.bufPrint(&row.name, "Row {d}", .{i}) catch unreachable).len;
            row.score = @intCast(i);
        }
        return t;
    }

    pub fn deinit(self: *State) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }
};

fn actionsCell(a: std.mem.Allocator, row: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "<button type=\"button\" class=\"row-menu-btn\" id=\"row-menu-{d}\" data-lv-click=\"zc:dropdown:toggle\" data-lv-value=\"{d}\">&#8942;</button>", .{ row, row });
}

fn tableLessThan(t: *State, x: usize, y: usize) bool {
    const rx = t.rows[x];
    const ry = t.rows[y];
    switch (t.sort_col) {
        0 => {
            const a = rx.name[0..rx.name_len];
            const b = ry.name[0..ry.name_len];
            return if (t.sort_asc) std.mem.lessThan(u8, a, b) else std.mem.lessThan(u8, b, a);
        },
        else => return if (t.sort_asc) rx.score < ry.score else rx.score > ry.score,
    }
}

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mountTable(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "edit_cell")) {
        return editCell(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "sort")) {
        return sortBy(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "input")) {
        return tableInput(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "zc:dropdown:toggle")) {
        const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
        const row = util.payloadIntLenient(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
        if (row < 0 or row >= table_rows) return h.sendErr(aa, env, "invalid_cell");
        const r: usize = @intCast(row);
        t.open_menu = if (t.open_menu == r) null else r;
        return pushTableUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "zc:dropdown:close")) {
        const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
        t.open_menu = null;
        return pushTableUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "menu_boost") or std.mem.eql(u8, env.event, "menu_clear")) {
        const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
        const row = util.payloadIntLenient(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
        if (row < 0 or row >= table_rows) return h.sendErr(aa, env, "invalid_cell");
        t.rows[@intCast(row)].score = if (env.event[5] == 'b') 100 else 0;
        t.open_menu = null;
        log.info("row {d} score -> {d}", .{ row, t.rows[@intCast(row)].score });
        return pushTableUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "zc:popover:toggle")) {
        const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
        t.popover_open = !t.popover_open;
        return pushTableUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "zc:popover:close")) {
        const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
        t.popover_open = false;
        return pushTableUpdate(h, aa, env.ref);
    }
    return h.sendErr(aa, env, "unknown_event");
}

fn tableInput(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
    const id = util.payloadString(env.payload, "id") orelse
        return h.sendErr(aa, env, "malformed");
    if (!std.mem.eql(u8, id, "sort-col")) return h.sendErr(aa, env, "unknown_field");
    const value = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    t.sort_col = if (std.mem.eql(u8, value, "name")) 0 else 1;
    log.info("table: sort by {s}", .{value});
    return pushTableUpdate(h, aa, env.ref);
}

fn editCell(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
    const row = util.payloadInt(env.payload, "row") orelse return h.sendErr(aa, env, "malformed");
    const col = util.payloadInt(env.payload, "col") orelse return h.sendErr(aa, env, "malformed");
    const value = util.payloadString(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
    if (row < 0 or row >= table_rows or col < 0 or col > 1)
        return h.sendErr(aa, env, "invalid_cell");

    const r: usize = @intCast(row);
    if (col == 0) {
        if (value.len == 0 or value.len > 24)
            return h.sendErr(aa, env, "invalid_value");
        const tr = &t.rows[r];
        @memcpy(tr.name[0..value.len], value);
        tr.name_len = value.len;
    } else {
        t.rows[r].score = std.fmt.parseInt(i64, value, 10) catch
            return h.sendErr(aa, env, "invalid_value");
    }
    log.info("table: cell ({d},{d}) = {s}", .{ row, col, value });
    return pushTableUpdate(h, aa, env.ref);
}

fn sortBy(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const t = h.table() orelse return h.sendErr(aa, env, "not_joined");
    const col = util.payloadInt(env.payload, "col") orelse return h.sendErr(aa, env, "malformed");
    if (col < 0 or col > 1) return h.sendErr(aa, env, "invalid_cell");
    const c: usize = @intCast(col);
    if (c == t.sort_col) {
        t.sort_asc = !t.sort_asc;
    } else {
        t.sort_col = c;
        t.sort_asc = true;
    }
    log.info("table: sort by {s} {s}", .{ table_columns[c].key, if (t.sort_asc) "asc" else "desc" });
    return pushTableUpdate(h, aa, env.ref);
}

fn mountTable(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    _ = try h.ensure("table", State, State.init);
    const tree = try renderTable(
        h,
    );
    log.info("mounted {s} ({d} rows)", .{ topic, table_rows });
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "render",
        .payload = try view.treeToValue(aa, tree),
        .ref = env.ref,
    });
}

fn renderTable(h: *Handler) ![]const view.Segment {
    const t = h.table().?;
    t.active = 1 - t.active;
    var arena = &t.arenas[t.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    const order = try a.alloc(usize, table_rows);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, t, tableLessThan);

    const rows = try a.alloc([]const view.Scalar, table_rows);
    for (order, 0..) |src, dst| {
        const cells = try a.alloc(view.Scalar, 3);
        // dupe + escape the name into the arena: the previous render
        // tree must stay a true snapshot, user input must be escaped
        cells[0] = .{ .string = try util.escapeHtml(a, t.rows[src].name[0..t.rows[src].name_len]) };
        cells[1] = .{ .int = t.rows[src].score };
        cells[2] = .{ .string = try actionsCell(a, src) };
        rows[dst] = cells;
    }
    const row_ids = try a.alloc([]const u8, table_rows);
    for (row_ids, 0..) |*id, i| {
        id.* = try std.fmt.allocPrint(a, "r{d}", .{i});
    }
    const table_tree = try view.Table.render(a, .{
        .columns = &table_columns,
        .rows = rows,
        .row_ids = row_ids,
    });

    // toolbar: styled native <select> for sorting (the pragmatic first
    // choice), a popover with info, and a tooltip on the sort label
    var toolbar: std.ArrayListUnmanaged(view.Segment) = .empty;
    try toolbar.appendSlice(a, &.{
        .text("<div class=\"tbl-toolbar\"><span id=\"about-sort\">Sort</span> "),
    });
    try toolbar.appendSlice(a, try view.Select.render(a, .{
        .id = "sort-col",
        .options = &sort_options,
        .value = if (t.sort_col == 0) "name" else "score",
    }));
    try toolbar.appendSlice(a, &.{
        .text(" <span class=\"toolbar-gap\"></span>"),
    });
    // heap-backed: the tree outlives this frame
    const popover_body = try a.alloc(view.Segment, 1);
    popover_body[0] = .text("<p>100 rows, live-editable. Double-click a cell to edit it; use &#8942; for row actions.</p>");
    try toolbar.appendSlice(a, try view.Popover.render(a, .{
        .id = "about-btn",
        .label = "About this table",
        .open = t.popover_open,
        .children = popover_body,
    }));
    try toolbar.append(a, .{ .children = try view.Tooltip.render(a, .{
        .anchor = "about-sort",
        .text = "Pick a column to sort by",
    }) });
    try toolbar.append(a, .text("</div>"));

    var total = toolbar.items.len + table_tree.len;
    var menu_node: ?view.Segment = null;
    if (t.open_menu) |m| {
        const row_str = try std.fmt.allocPrint(a, "{d}", .{m});
        const items = try a.alloc(view.Dropdown.Item, 2);
        items[0] = .{ .label = "Set score to 100", .event = "menu_boost", .value = row_str };
        items[1] = .{ .label = "Reset score", .event = "menu_clear", .value = row_str };
        const id = try std.fmt.allocPrint(a, "row-menu-{d}", .{m});
        menu_node = .{ .children = try view.DropdownPanel.render(a, .{ .id = id, .items = items, .placement = "bottom-end" }) };
        total += 1;
    }

    const tree = try a.alloc(view.Segment, total);
    @memcpy(tree[0..toolbar.items.len], toolbar.items);
    @memcpy(tree[toolbar.items.len..][0..table_tree.len], table_tree);
    if (menu_node) |node| tree[total - 1] = node;
    t.trees[t.active] = tree;
    return tree;
}

fn pushTableUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const t = h.table().?;
    const previous = t.trees[t.active];
    const current = try renderTable(
        h,
    );
    var patches = try view.diff(aa, previous, current);
    defer patches.deinit();
    log.info("table: {d} patch(es)", .{patches.count()});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "patch",
        .payload = try patches.toValue(aa),
        .ref = ref,
    });
}

test "table state: edit produces a one-cell diff" {
    const allocator = std.testing.allocator;

    var t = State.init(allocator);
    defer t.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rowsOf = struct {
        fn f(a: std.mem.Allocator, state: *State) ![]const []const view.Scalar {
            const rows = try a.alloc([]const view.Scalar, table_rows);
            for (&state.rows, 0..) |*row, i| {
                const cells = try a.alloc(view.Scalar, 3);
                cells[0] = .{ .string = try util.escapeHtml(a, row.name[0..row.name_len]) };
                cells[1] = .{ .int = row.score };
                cells[2] = .{ .string = try actionsCell(a, i) };
                rows[i] = cells;
            }
            return rows;
        }
    }.f;

    const before = try view.Table.render(arena.allocator(), .{
        .columns = &table_columns,
        .rows = try rowsOf(arena.allocator(), &t),
    });

    @memcpy(t.rows[7].name[0..5], "Lucky");
    t.rows[7].name_len = 5;

    const after = try view.Table.render(arena.allocator(), .{
        .columns = &table_columns,
        .rows = try rowsOf(arena.allocator(), &t),
    });

    var patches = try view.diff(allocator, before, after);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("11.7.2", patches.at(0).path); // 3 columns
    try std.testing.expectEqualStrings("Lucky", patches.at(0).node.dynamic.string);
}
