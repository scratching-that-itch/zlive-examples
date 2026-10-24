const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;
const countries_data = @import("countries_data");
const detail_panel = @import("detail");

const log = std.log.scoped(.ziggy);

pub const topic = "view:countries";

const Country = countries_data.Country;
const countries = countries_data.countries;
pub const dataset = countries_data.countries;

pub const countries_columns = [_]view.Table.Column{
    .{ .key = "name", .label = "Name" },
    .{ .key = "capital", .label = "Capital" },
    .{ .key = "region", .label = "Region" },
    .{ .key = "pop", .label = "Population" },
    .{ .key = "area", .label = "Area (km²)" },
    .{ .key = "actions", .label = "" },
};

const page_size_options = [_]usize{ 10, 25, 50, 100 };

pub const State = struct {
    sort_col: usize = 0,
    sort_asc: bool = true,
    selected: ?usize = null,
    page: usize = 0,
    page_size: usize = 10,
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active: usize = 0,

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

/// Column sort state; the detail panel shares this type.
pub const CountrySort = detail_panel.Sort;

fn countryLessThan(s: CountrySort, x: usize, y: usize) bool {
    const a = countries[x];
    const b = countries[y];
    switch (s.col) {
        0 => return if (s.asc) std.mem.lessThan(u8, a.name, b.name) else std.mem.lessThan(u8, b.name, a.name),
        1 => return if (s.asc) std.mem.lessThan(u8, a.capital, b.capital) else std.mem.lessThan(u8, b.capital, a.capital),
        2 => return if (s.asc) std.mem.lessThan(u8, a.region, b.region) else std.mem.lessThan(u8, b.region, a.region),
        3 => return if (s.asc) a.pop < b.pop else a.pop > b.pop,
        4 => return if (s.asc) a.area_km2 < b.area_km2 else a.area_km2 > b.area_km2,
        else => return false,
    }
}

pub const Parts = struct {
    table: []view.Segment,
    controls: []view.Segment,
    detail: view.Segment, // children node; empty when nothing selected
};

pub fn buildCountriesParts(
    a: std.mem.Allocator,
    sort: CountrySort,
    page: usize,
    page_size: usize,
    selected: ?usize,
) !Parts {
    const order = try a.alloc(usize, countries.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, sort, countryLessThan);

    const page_count = (countries.len + page_size - 1) / page_size;
    const cur_page = @min(page, page_count - 1);
    const start = cur_page * page_size;
    const stop = @min(start + page_size, countries.len);

    const rows = try a.alloc([]const view.Scalar, stop - start);
    const row_ids = try a.alloc([]const u8, stop - start);
    for (order[start..stop], 0..) |src_i, dst| {
        const country = countries[src_i];
        const cells = try a.alloc(view.Scalar, 6);
        cells[0] = .{ .string = country.name };
        cells[1] = .{ .string = country.capital };
        cells[2] = .{ .string = country.region };
        cells[3] = .{ .string = try countries_data.formatPop(a, country.pop) };
        cells[4] = .{ .int = country.area_km2 };
        const active = selected != null and selected.? == src_i;
        // The info button is markup by construction: the raw-HTML opt-in
        // (Scalar.html). Every other cell is text and renders escaped.
        cells[5] = .{ .html = try std.fmt.allocPrint(a, "<button type=\"button\" class=\"info-btn{s}\" id=\"country-{d}\" data-lv-click=\"select_country\" data-lv-value=\"{d}\" aria-label=\"Show {s} details\">&#9432;</button>", .{ if (active) " active" else "", src_i, src_i, country.name }) };
        rows[dst] = cells;
        row_ids[dst] = try std.fmt.allocPrint(a, "c{d}", .{src_i});
    }
    const table = try view.Table.render(a, .{
        .columns = &countries_columns,
        .rows = rows,
        .row_ids = row_ids,
        .sort = .{ .col = sort.col, .asc = sort.asc },
    });

    var controls: std.ArrayListUnmanaged(view.Segment) = .empty;
    try controls.appendSlice(a, &.{
        .text("<div class=\"tbl-controls\"><button type=\"button\" data-lv-click=\"paginate\" data-lv-value=\"prev\""),
        .text(if (cur_page == 0) " disabled" else ""),
        .text(">&lsaquo; Prev</button><span class=\"page-info\">"),
        .{ .dynamic = .{ .string = try std.fmt.allocPrint(a, "Page {d} / {d} · rows {d}–{d} of {d}", .{ cur_page + 1, page_count, start + 1, stop, countries.len }) } },
        .text("</span><button type=\"button\" data-lv-click=\"paginate\" data-lv-value=\"next\""),
        .text(if (cur_page + 1 >= page_count) " disabled" else ""),
        .text(">Next &rsaquo;</button><span class=\"gap\"></span><label for=\"page-size\">Rows per page</label> "),
    });
    const page_size_opts = try a.alloc(view.Select.Option_, page_size_options.len);
    for (page_size_options, 0..) |size, i| {
        page_size_opts[i] = .{
            .value = try std.fmt.allocPrint(a, "{d}", .{size}),
            .label = try std.fmt.allocPrint(a, "{d}", .{size}),
        };
    }
    try controls.appendSlice(a, try view.Select.render(a, .{
        .id = "page-size",
        .options = page_size_opts,
        .value = try std.fmt.allocPrint(a, "{d}", .{page_size}),
    }));
    try controls.append(a, .text("</div>"));

    // The detail panel is a Card (see views/detail.zig), so the master-detail
    // layout is built from the same primitives as any other page.
    const detail = try detail_panel.render(a, .{ .selected = selected, .sort = sort });

    return .{
        .table = table,
        .controls = try controls.toOwnedSlice(a),
        .detail = detail,
    };
}

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mountCountries(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "sort")) {
        const c = h.countries() orelse return h.sendErr(aa, env, "not_joined");
        // sortable headers send data-lv-value -> {id, value}; older
        // clients may send {col}
        const col = util.payloadIntLenient(env.payload, "value") orelse
            util.payloadIntLenient(env.payload, "col") orelse
            return h.sendErr(aa, env, "malformed");
        if (col < 0 or col > 4) return h.sendErr(aa, env, "invalid_cell");
        const k: usize = @intCast(col);
        if (k == c.sort_col) {
            c.sort_asc = !c.sort_asc;
        } else {
            c.sort_col = k;
            c.sort_asc = true;
        }
        log.info("countries: sort by {s} {s}", .{ countries_columns[k].key, if (c.sort_asc) "asc" else "desc" });
        return pushCountriesUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "select_country")) {
        const c = h.countries() orelse return h.sendErr(aa, env, "not_joined");
        const idx = util.payloadIntLenient(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
        if (idx < 0 or idx >= countries.len) return h.sendErr(aa, env, "invalid_cell");
        const i: usize = @intCast(idx);
        c.selected = if (c.selected == i) null else i; // toggle
        log.info("countries: selected {?s}", .{if (c.selected) |s| countries[s].name else null});
        return pushCountriesUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "close_details")) {
        const c = h.countries() orelse return h.sendErr(aa, env, "not_joined");
        c.selected = null;
        return pushCountriesUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "paginate")) {
        const c = h.countries() orelse return h.sendErr(aa, env, "not_joined");
        const dir = util.payloadString(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
        const page_count = (countries.len + c.page_size - 1) / c.page_size;
        if (std.mem.eql(u8, dir, "next")) {
            if (c.page + 1 < page_count) c.page += 1;
        } else if (std.mem.eql(u8, dir, "prev")) {
            if (c.page > 0) c.page -= 1;
        } else {
            return h.sendErr(aa, env, "malformed");
        }
        log.info("countries: page {d}/{d}", .{ c.page + 1, page_count });
        return pushCountriesUpdate(h, aa, env.ref);
    }
    if (std.mem.eql(u8, env.event, "input")) {
        const c = h.countries() orelse return h.sendErr(aa, env, "not_joined");
        const id = util.payloadString(env.payload, "id") orelse return h.sendErr(aa, env, "malformed");
        if (!std.mem.eql(u8, id, "page-size")) return h.sendErr(aa, env, "unknown_field");
        const size = util.payloadIntLenient(env.payload, "value") orelse return h.sendErr(aa, env, "malformed");
        if (size != 10 and size != 25 and size != 50 and size != 100)
            return h.sendErr(aa, env, "invalid_value");
        c.page_size = @intCast(size);
        c.page = 0; // back to the first page
        log.info("countries: page size {d}", .{c.page_size});
        return pushCountriesUpdate(h, aa, env.ref);
    }
    return h.sendErr(aa, env, "unknown_event");
}

fn mountCountries(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    _ = try h.ensure("countries", State, State.init);
    const tree = try renderCountriesView(
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

fn renderCountriesView(h: *Handler) ![]const view.Segment {
    const c = h.countries().?;
    c.active = 1 - c.active;
    var arena = &c.arenas[c.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    const parts = try buildCountriesParts(a, .{
        .col = c.sort_col,
        .asc = c.sort_asc,
    }, c.page, c.page_size, c.selected);

    // layout: <div class="layout"><div class="tbl-wrap"> TABLE
    // CONTROLS </div> DETAIL </div> - identical to the kitchen sink's
    // table section (shared builder, shared CSS, same composition).
    // Sorting is via header clicks; the page-size Select is part of
    // the shared controls.
    const tree = try a.alloc(view.Segment, parts.table.len + parts.controls.len + 4);
    tree[0] = .text("<div class=\"layout\"><div class=\"tbl-wrap\">");
    var at: usize = 1;
    @memcpy(tree[at..][0..parts.table.len], parts.table);
    at += parts.table.len;
    @memcpy(tree[at..][0..parts.controls.len], parts.controls);
    at += parts.controls.len;
    tree[at] = .text("</div>");
    tree[at + 1] = parts.detail;
    tree[at + 2] = .text("</div>");
    c.trees[c.active] = tree;
    return tree;
}

fn pushCountriesUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const c = h.countries().?;
    const previous = c.trees[c.active];
    const current = try renderCountriesView(
        h,
    );
    var patches = try view.diff(aa, previous, current);
    defer patches.deinit();
    log.info("countries: {d} patch(es)", .{patches.count()});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "patch",
        .payload = try patches.toValue(aa),
        .ref = ref,
    });
}
