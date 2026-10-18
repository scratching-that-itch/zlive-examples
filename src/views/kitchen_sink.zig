const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;
const countries = @import("countries");
const countries_data = @import("countries_data");

const log = std.log.scoped(.ziggy);

pub const topic = "view:kitchen";

const kitchen_tabs = [_][]const u8{ "alpha", "beta", "gamma" };
const kitchen_acc_keys = [_][]const u8{ "one", "two", "three" };
const kitchen_acc_titles = [_][]const u8{ "First section", "Second section", "Third section" };
const kitchen_tab_content = [_][]const u8{
    "The first tab's content.",
    "The second tab's content.",
    "The third tab's content.",
};
const kitchen_acc_content = [_][]const u8{
    "Content of the first accordion section.",
    "Content of the second accordion section.",
    "Content of the third accordion section.",
};
/// What the "Show three" button queues: the stack at capacity, each item
/// with its own level and deadline.
const kitchen_burst = [_]struct { message: []const u8, level: view.Toast.Level, ttl_ms: u64 }{
    .{ .message = "First: the stack grows", .level = .info, .ttl_ms = 20_000 },
    .{ .message = "Second: its own deadline", .level = .success, .ttl_ms = 20_000 },
    .{ .message = "Third: close one and the rest close the gap", .level = .err, .ttl_ms = 20_000 },
};

const kitchen_roles = [_]view.Select.Option_{
    .{ .value = "user", .label = "User" },
    .{ .value = "admin", .label = "Admin" },
};

pub const State = struct {
    count: i64 = 0,
    tabs_active: usize = 0,
    acc_open: [3]bool = .{ true, false, false },
    dialog_open: bool = false,
    dropdown_open: bool = false,
    popover_open: bool = false,
    // Checkbox/radio/submenu state for the shadcn-style dropdown menu: the
    // server owns all three, so each is a patch when it changes.
    dd_details: bool = false,
    dd_sort: usize = 0,
    dd_sub_open: ?[]const u8 = null,
    // Toast: which corner the region pins to.
    toast_corner: view.ToastRegion.Corner = .bottom_right,
    // countries table (full feature set, same as view:countries)
    sort_col: usize = 0,
    sort_asc: bool = true,
    page: usize = 0,
    page_size: usize = 10,
    selected: ?usize = null,
    // form state
    f_name: [64]u8 = undefined,
    f_name_len: usize = 0,
    f_email: [64]u8 = undefined,
    f_email_len: usize = 0,
    f_role: usize = 0,
    f_sub: bool = false,
    f_submitting: bool = false,
    f_status: []const u8 = "",
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

    fn nameError(self: *const State) ?[]const u8 {
        if (self.f_name_len == 0) return null;
        if (self.f_name_len < 3) return "at least 3 characters";
        return null;
    }

    fn emailError(self: *const State) ?[]const u8 {
        if (self.f_email_len == 0) return null;
        if (std.mem.indexOfScalar(u8, self.f_email[0..self.f_email_len], '@') == null)
            return "must contain @";
        return null;
    }

    fn formValid(self: *const State) bool {
        return self.f_name_len >= 3 and
            std.mem.indexOfScalar(u8, self.f_email[0..self.f_email_len], '@') != null;
    }
};

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mount(h, aa, env);
    }
    const state = h.kitchen() orelse return h.sendErr(aa, env, "not_joined");
    const event = env.event;

    if (std.mem.eql(u8, event, "inc")) {
        state.count += 1;
    } else if (std.mem.eql(u8, event, "flash")) {
        return flashShow(h, aa, env);
    } else if (std.mem.eql(u8, event, "toast_show")) {
        return toastShow(h, aa, env);
    } else if (std.mem.eql(u8, event, "toast_burst")) {
        // Three at once: enough to fill the queue, with staggered deadlines
        // so the stack drains one at a time.
        for (kitchen_burst) |b| _ = try h.showToast(b.message, b.level, b.ttl_ms);
    } else if (std.mem.eql(u8, event, "toast_corner")) {
        // Pushes its own update: a rejected corner must not also send an
        // empty patch, or the client gets two replies for one event.
        return toastCorner(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "zc:toast:dismiss")) {
        // The close button reports *which* toast: with a stack up, "dismiss
        // one" is ambiguous without the id the region rendered into it.
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        const id = std.fmt.parseInt(u64, value, 10) catch
            return h.sendErr(aa, env, "invalid_value");
        if (!try h.dismissToast(id)) return h.sendErr(aa, env, "unknown_notification");
    } else if (std.mem.eql(u8, event, "switch_tab")) {
        try tabSwitch(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "toggle_section")) {
        try sectionToggle(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "input")) {
        try inputReceive(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "submit")) {
        try submitForm(h, aa, env, state);
    } else if (std.mem.eql(u8, event, "open_dialog")) {
        state.dialog_open = true;
    } else if (std.mem.eql(u8, event, "zc:dialog:close")) {
        state.dialog_open = false;
    } else if (std.mem.eql(u8, event, "zc:dropdown:toggle")) {
        state.dropdown_open = !state.dropdown_open;
        state.dd_sub_open = null;
    } else if (std.mem.eql(u8, event, "zc:dropdown:close")) {
        state.dropdown_open = false;
        state.dd_sub_open = null;
    } else if (std.mem.eql(u8, event, "zc:dropdown:sub")) {
        try submenuToggle(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "ks_dd_details")) {
        // shadcn keeps the menu open for checkbox/radio rows, so this
        // deliberately does not close it.
        state.dd_details = !state.dd_details;
    } else if (std.mem.eql(u8, event, "ks_dd_sort")) {
        const value = util.payloadString(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        state.dd_sort = std.fmt.parseInt(usize, value, 10) catch
            return h.sendErr(aa, env, "malformed");
        if (state.dd_sort > 2) return h.sendErr(aa, env, "invalid_value");
    } else if (std.mem.eql(u8, event, "ks_share")) {
        // A leaf row in the submenu: selecting one closes the whole menu,
        // which is what shadcn's DropdownMenu does.
        state.dd_sub_open = null;
        state.dropdown_open = false;
    } else if (std.mem.eql(u8, event, "zc:popover:toggle")) {
        state.popover_open = !state.popover_open;
    } else if (std.mem.eql(u8, event, "zc:popover:close")) {
        state.popover_open = false;
    } else if (std.mem.eql(u8, event, "ks_action")) {
        try menuAction(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "sort")) {
        try sortReceive(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "paginate")) {
        try paginateReceive(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "select_country")) {
        try countrySelect(h, state, aa, env);
    } else if (std.mem.eql(u8, event, "close_details")) {
        state.selected = null;
    } else {
        return h.sendErr(aa, env, "unknown_event");
    }

    return pushUpdate(h, aa, env.ref);
}

fn tabSwitch(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const key = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    for (kitchen_tabs, 0..) |tab, i| {
        if (std.mem.eql(u8, tab, key)) state.tabs_active = i;
    }
}

fn sectionToggle(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const key = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    for (kitchen_acc_keys, 0..) |section_key, i| {
        if (std.mem.eql(u8, section_key, key)) state.acc_open[i] = !state.acc_open[i];
    }
}

fn menuAction(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const value = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    if (std.mem.eql(u8, value, "bump")) {
        state.count += 10;
    } else if (std.mem.eql(u8, value, "reset")) {
        state.count = 0;
    }
    // A plain menu row closes the menu, and with it any open submenu.
    state.dropdown_open = false;
    state.dd_sub_open = null;
}

/// The sub-trigger is a disclosure inside the menu: the server owns which
/// submenu is open (a patch), the hook owns positioning it.
fn submenuToggle(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const key = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    if (state.dd_sub_open) |open| {
        state.dd_sub_open = if (std.mem.eql(u8, open, key)) null else key;
    } else {
        state.dd_sub_open = key;
    }
}

fn sortReceive(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const col = util.payloadIntLenient(env.payload, "value") orelse
        util.payloadIntLenient(env.payload, "col") orelse
        return h.sendErr(aa, env, "malformed");
    if (col < 0 or col > 4) return h.sendErr(aa, env, "invalid_cell");
    const c: usize = @intCast(col);
    if (c == state.sort_col) {
        state.sort_asc = !state.sort_asc;
    } else {
        state.sort_col = c;
        state.sort_asc = true;
    }
}

fn paginateReceive(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const dir = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    const page_count = (countries.dataset.len + state.page_size - 1) / state.page_size;
    if (std.mem.eql(u8, dir, "next")) {
        if (state.page + 1 < page_count) state.page += 1;
    } else if (std.mem.eql(u8, dir, "prev")) {
        if (state.page > 0) state.page -= 1;
    } else {
        return h.sendErr(aa, env, "malformed");
    }
}

fn countrySelect(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const idx = util.payloadIntLenient(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    if (idx < 0 or idx >= countries.dataset.len)
        return h.sendErr(aa, env, "invalid_cell");
    const i: usize = @intCast(idx);
    state.selected = if (state.selected == i) null else i;
}

fn inputReceive(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const id = util.payloadString(env.payload, "id") orelse
        return h.sendErr(aa, env, "malformed");
    const value = util.payloadString(env.payload, "value");

    if (std.mem.eql(u8, id, "ks-name")) {
        const v = value orelse return h.sendErr(aa, env, "malformed");
        if (v.len > state.f_name.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(state.f_name[0..v.len], v);
        state.f_name_len = v.len;
    } else if (std.mem.eql(u8, id, "ks-email")) {
        const v = value orelse return h.sendErr(aa, env, "malformed");
        if (v.len > state.f_email.len) return h.sendErr(aa, env, "invalid_value");
        @memcpy(state.f_email[0..v.len], v);
        state.f_email_len = v.len;
    } else if (std.mem.eql(u8, id, "ks-role")) {
        const v = value orelse return h.sendErr(aa, env, "malformed");
        state.f_role = if (std.mem.eql(u8, v, "admin")) 1 else 0;
    } else if (std.mem.eql(u8, id, "ks-sub")) {
        const p = env.payload orelse return h.sendErr(aa, env, "malformed");
        if (p != .object) return h.sendErr(aa, env, "malformed");
        const v = p.object.get("value") orelse return h.sendErr(aa, env, "malformed");
        if (v != .bool) return h.sendErr(aa, env, "malformed");
        state.f_sub = v.bool;
    } else if (std.mem.eql(u8, id, "page-size")) {
        const size = util.payloadIntLenient(env.payload, "value") orelse
            return h.sendErr(aa, env, "malformed");
        if (size != 10 and size != 25 and size != 50 and size != 100)
            return h.sendErr(aa, env, "invalid_value");
        state.page_size = @intCast(size);
        state.page = 0;
    } else {
        return h.sendErr(aa, env, "unknown_field");
    }
}

fn submitForm(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope, state: *State) !void {
    if (!state.formValid()) {
        state.f_status = "Please fix the errors above.";
        return;
    }
    state.f_submitting = true;
    state.f_status = "Saving…";
    try pushUpdate(h, aa, env.ref);
    state.f_submitting = false;
    state.f_status = "Saved!";
}

fn flashShow(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const message = util.payloadString(env.payload, "message") orelse "Flash!";
    const ttl: u64 = @intCast(@min(util.payloadInt(env.payload, "ttl_ms") orelse 3000, 60_000));
    _ = try h.showBanner(message, .info, ttl);
    return pushUpdate(h, aa, env.ref);
}

/// Shows a toast: the same queue as the inline banner, at capacity three and
/// with the corner-stack presentation, so each show appends one item and
/// each expiry removes one.
fn toastShow(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const message = util.payloadString(env.payload, "message") orelse "Toast!";
    const level_tag = util.payloadString(env.payload, "level") orelse "info";
    const level: view.Toast.Level = if (std.mem.eql(u8, level_tag, "err"))
        .err
    else if (std.mem.eql(u8, level_tag, "success"))
        .success
    else
        .info;
    const ttl: u64 = @intCast(@min(util.payloadInt(env.payload, "ttl_ms") orelse 3000, 60_000));
    _ = try h.showToast(message, level, ttl);
    return pushUpdate(h, aa, env.ref);
}

fn toastCorner(h: *Handler, state: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const value = util.payloadString(env.payload, "value") orelse
        return h.sendErr(aa, env, "malformed");
    state.toast_corner = view.ToastRegion.Corner.fromTag(value) orelse
        return h.sendErr(aa, env, "invalid_value");
    return pushUpdate(h, aa, env.ref);
}

fn mount(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    _ = try h.ensure("kitchen", State, State.init);
    const tree = try render(h);
    log.info("mounted {s}", .{topic});
    try h.send(aa, .{
        .type = .message,
        .topic = topic,
        .event = "render",
        .payload = try view.treeToValue(aa, tree),
        .ref = env.ref,
    });
}

fn render(h: *Handler) ![]const view.Segment {
    const state = h.kitchen().?;
    state.active = 1 - state.active;
    var arena = &state.arenas[state.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    var body: std.ArrayListUnmanaged(view.Segment) = .empty;
    try sectionCounter(a, &body, state);
    try sectionFlash(h, a, &body);
    try sectionToast(h, a, &body, state);
    try sectionTabs(a, &body, state);
    try sectionAccordion(a, &body, state);
    try sectionForm(a, &body, state);
    try sectionOverlays(a, &body, state);
    try sectionTable(a, &body, state);
    try sectionCard(a, &body);

    return finishTree(a, &body, state);
}

/// The queues' reapers call this when a banner or toast expires: re-render
/// and push the patch, exactly as an event would. It runs with the app lock
/// already held (the reaper holds it), from the reaper's thread.
pub fn flush(h: *Handler) void {
    if (h.kitchen() == null) return; // this session is not showing the kitchen sink
    var arena = std.heap.ArenaAllocator.init(h.app().allocator);
    defer arena.deinit();
    pushUpdate(h, arena.allocator(), null) catch |err| {
        log.warn("kitchen flush failed: {t}", .{err});
    };
}

fn pushUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const state = h.kitchen().?;
    // Lock held from render through encode: the notification queues' items
    // are read here, and their reapers free messages under the same lock.
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const previous = state.trees[state.active];
        const current = try render(h);
        var patches = try view.diff(aa, previous, current);
        defer patches.deinit();
        log.info("kitchen: {d} patch(es)", .{patches.count()});
        const reply = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "patch",
            .payload = try patches.toValue(aa),
            .ref = ref,
        };
        break :blk try reply.encode(aa);
    };
    try h.service.conn.write(json);
}

fn sectionCounter(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.appendSlice(a, &.{
        .text("<section><h2>Counter &amp; Button</h2><p class=\"ks-count\">count: "),
        .{ .dynamic = .{ .int = state.count } },
        .text("</p>"),
    });
    try body.appendSlice(a, try view.Button.render(a, .{ .label = "+", .on_click = "inc" }));
    try body.append(a, .text("<p class=\"ks-note\">shadcn's six variants, no events — they exist to be looked at:</p>"));

    // The variant row and the size row are Clusters so they wrap. Every
    // button here is static (no on_click, no state), so the whole showcase
    // costs no patches after mount.
    const variants = [_]view.Button.Variant{
        .@"default", .outline, .secondary, .ghost, .destructive, .link,
    };
    const variant_labels = [_][]const u8{ "Default", "Outline", "Secondary", "Ghost", "Destructive", "Link" };
    var variant_row: std.ArrayListUnmanaged(view.Segment) = .empty;
    inline for (variants, variant_labels) |variant, label| {
        try variant_row.appendSlice(a, try view.Button.render(a, .{
            .label = label,
            .variant = variant,
            .size = .sm,
        }));
    }
    try body.appendSlice(a, try view.Cluster.render(a, .{
        .gap = .sm,
        .children = variant_row.items,
    }));

    const sizes = [_]view.Button.Size{ .xs, .sm, .@"default", .lg };
    const size_labels = [_][]const u8{ "xs", "sm", "default", "lg" };
    var size_row: std.ArrayListUnmanaged(view.Segment) = .empty;
    inline for (sizes, size_labels) |size, label| {
        try size_row.appendSlice(a, try view.Button.render(a, .{
            .label = label,
            .variant = .outline,
            .size = size,
        }));
    }
    // The four square icon sizes, with aria-labels (their glyph is the label).
    const icon_sizes = [_]view.Button.Size{ .@"icon-xs", .@"icon-sm", .icon, .@"icon-lg" };
    inline for (icon_sizes) |size| {
        try size_row.appendSlice(a, try view.Button.render(a, .{
            .label = "&#8942;",
            .variant = .ghost,
            .size = size,
            .aria_label = "More",
        }));
    }
    try body.appendSlice(a, try view.Cluster.render(a, .{
        .gap = .sm,
        .children = size_row.items,
    }));
    try body.append(a, .text("</section>"));
}

// The inline banner: one node in the section list, holding the banner
// queue's items (at most one, since that queue's capacity is 1). Showing
// another replaces it through the ordinary diff — the queue is the state,
// the tree is derived from it.
fn sectionFlash(h: *Handler, a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment)) !void {
    try body.append(a, .text("<section><h2>Flash</h2>"));
    // The payload prop carries the JSON the client parses and sends as the
    // event payload.
    try body.appendSlice(a, try view.Button.render(a, .{
        .label = "Show flash",
        .variant = .secondary,
        .on_click = "flash",
        .payload = "{\"message\":\"Saved!\",\"ttl_ms\":3000}",
    }));
    try body.append(a, .text(" "));
    var items: std.ArrayListUnmanaged(view.Segment) = .empty;
    for ((try h.bannerQueue()).items()) |item| {
        try items.appendSlice(a, try view.Flash.render(a, item.props));
    }
    var slot_children: std.ArrayListUnmanaged(view.Segment) = .empty;
    try slot_children.append(a, .text("<div class=\"ks-flash-slot\">"));
    try slot_children.appendSlice(a, items.items);
    try slot_children.append(a, .text("</div>"));
    try body.appendSlice(a, &.{
        .{ .children = if (items.items.len == 0) &.{} else try slot_children.toOwnedSlice(a) },
        .text("</section>"),
    });
}

// The corner stack: the region exists from mount and its children slot is
// the queue's items, oldest first. Showing a toast patches the appended
// index; expiring or closing one compacts the list, so the survivors shift
// up. `column-reverse` in the top corners is what puts the newest nearest
// the edge (see zc.css).
fn sectionToast(h: *Handler, a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.append(a, .text("<section><h2>Toast</h2>"));
    try body.append(a, .text(
        "<p class=\"ks-note\">Toasts pop over a corner, one per notification, " ++
            "each with its own deadline and its own close button. Pick the corner, " ++
            "then show a few.</p>",
    ));

    // One button per corner; the active one is filled. This is a Button
    // variant change, so switching corners is one patch on the button and
    // one on the region.
    const corners = [_]view.ToastRegion.Corner{ .top_left, .top_right, .bottom_left, .bottom_right };
    var row: std.ArrayListUnmanaged(view.Segment) = .empty;
    inline for (corners) |corner| {
        try row.appendSlice(a, try view.Button.render(a, .{
            .label = corner.tag(),
            .variant = if (corner == state.toast_corner) .@"default" else .outline,
            .size = .sm,
            .on_click = "toast_corner",
            .value = corner.tag(),
        }));
    }
    try body.appendSlice(a, try view.Cluster.render(a, .{
        .gap = .sm,
        .children = row.items,
    }));
    try body.append(a, .text(" "));
    try body.appendSlice(a, try view.Button.render(a, .{
        .label = "Show toast",
        .size = .sm,
        .on_click = "toast_show",
        .payload = "{\"message\":\"Saved to your workspace\",\"level\":\"success\",\"ttl_ms\":3000}",
    }));
    try body.append(a, .text(" "));
    try body.appendSlice(a, try view.Button.render(a, .{
        .label = "Show error toast",
        .variant = .destructive,
        .size = .sm,
        .on_click = "toast_show",
        .payload = "{\"message\":\"Upload failed\",\"level\":\"err\",\"ttl_ms\":4000}",
    }));
    try body.append(a, .text(" "));
    // Three in a row: the stack, and the queue's capacity (3). The fourth
    // would evict the oldest, which is what a bounded stack should do.
    try body.appendSlice(a, try view.Button.render(a, .{
        .label = "Show three",
        .variant = .outline,
        .size = .sm,
        .on_click = "toast_burst",
    }));

    // The region's children: the queue's items, oldest first, each rendered
    // with the id its close button reports. One *child node per toast* — not
    // their segments spliced into one list — is what lets the diff add,
    // replace and drop individual toasts instead of re-patching a
    // concatenated block.
    var toasts: std.ArrayListUnmanaged(view.Segment) = .empty;
    for ((try h.toastQueue()).items()) |item| {
        try toasts.append(a, .{ .children = try view.Toast.render(a, .{
            .id = try std.fmt.allocPrint(a, "{d}", .{item.id}),
            .message = item.props.message,
            .level = item.props.level,
        }) });
    }
    try body.append(a, .{ .children = try view.ToastRegion.render(a, .{
        .corner = state.toast_corner,
        .children = toasts.items,
    }) });
    try body.append(a, .text("</section>"));
}

fn sectionTabs(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.append(a, .text("<section><h2>Tabs</h2>"));
    var tabs_list: std.ArrayListUnmanaged(view.Tabs.Tab) = .empty;
    for (kitchen_tabs, 0..) |key, i| {
        const content = try a.alloc(view.Segment, 1);
        content[0] = .{ .dynamic = .{ .string = kitchen_tab_content[i] } };
        try tabs_list.append(a, .{ .key = key, .label = key, .content = content });
    }
    try body.appendSlice(a, try view.Tabs.render(a, .{
        .id = "ks-tabs",
        .tabs = tabs_list.items,
        .active = kitchen_tabs[state.tabs_active],
    }));
    try body.append(a, .text("</section>"));
}

fn sectionAccordion(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.append(a, .text("<section><h2>Accordion</h2>"));
    var open_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var sections_list: std.ArrayListUnmanaged(view.Accordion.Section) = .empty;
    for (kitchen_acc_keys, 0..) |key, i| {
        const content = try a.alloc(view.Segment, 1);
        content[0] = .{ .dynamic = .{ .string = kitchen_acc_content[i] } };
        try sections_list.append(a, .{
            .key = key,
            .title = kitchen_acc_titles[i],
            .content = content,
        });
        if (state.acc_open[i]) try open_list.append(a, key);
    }
    try body.appendSlice(a, try view.Accordion.render(a, .{
        .id = "ks-acc",
        .sections = sections_list.items,
        .open = open_list.items,
    }));
    try body.append(a, .text("</section>"));
}

fn sectionForm(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.append(a, .text("<section><h2>Form</h2>"));
    var children: std.ArrayListUnmanaged(view.Segment) = .empty;
    try children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "ks-name",
        .value = try std.fmt.allocPrint(a, "{s}", .{state.f_name[0..state.f_name_len]}),
        .placeholder = "your name",
        .error_msg = state.nameError(),
    }));
    try children.appendSlice(a, try view.TextInput.render(a, .{
        .id = "ks-email",
        .value = try std.fmt.allocPrint(a, "{s}", .{state.f_email[0..state.f_email_len]}),
        .placeholder = "you@example.com",
        .error_msg = state.emailError(),
    }));
    try children.appendSlice(a, try view.Select.render(a, .{
        .id = "ks-role",
        .options = &kitchen_roles,
        .value = kitchen_roles[state.f_role].value,
    }));
    try children.appendSlice(a, try view.Checkbox.render(a, .{
        .id = "ks-sub",
        .label = "Subscribe",
        .checked = state.f_sub,
    }));
    try children.appendSlice(a, try view.SubmitButton.render(a, .{
        .label = "Save",
        .loading = state.f_submitting,
    }));
    try children.appendSlice(a, &.{
        .text("<p class=\"status\">"),
        .{ .dynamic = .{ .string = state.f_status } },
        .text("</p>"),
    });
    try body.appendSlice(a, try view.Form.render(a, .{
        .id = "ks-form",
        .submitting = state.f_submitting,
        .children = children.items,
    }));
    try body.append(a, .text("</section>"));
}

fn sectionOverlays(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    try body.append(a, .text("<section><h2>Overlays</h2>"));
    try body.appendSlice(a, try view.Button.render(a, .{
        .label = "Open dialog",
        .on_click = "open_dialog",
    }));
    try body.appendSlice(a, &.{
        .text(" "),
        // Anchored disclosure triggers: the id is what data-zc-anchor
        // resolves (Floating UI), and aria-expanded mirrors server state.
        // Both are outline Buttons, which is what shadcn wraps its
        // DropdownMenuTrigger / PopoverTrigger in.
        .{ .children = try view.Button.render(a, .{
            .label = "Actions ▾",
            .variant = .outline,
            .id = "ks-dd-trigger",
            .on_click = "zc:dropdown:toggle",
            .value = "ks-dd",
            .aria_expanded = state.dropdown_open,
        }) },
        .text(" "),
        .{ .children = try view.Button.render(a, .{
            .label = "About",
            .variant = .outline,
            .id = "ks-pop-trigger",
            .on_click = "zc:popover:toggle",
            .value = "ks-pop",
            .aria_expanded = state.popover_open,
        }) },
        .text(" "),
        .text("<span id=\"ks-tip-anchor\" class=\"tip-anchor\">hover for tooltip</span> <span id=\"ks-tip2-anchor\" class=\"tip-anchor\">second tip</span>"),
    });

    // The dropdown's checkbox and radio rows are server state, so showing it
    // outside the menu is what makes the patches observable (and testable).
    const sort_labels = [_][]const u8{ "name", "size", "date" };
    try body.appendSlice(a, &.{
        .text("<p class=\"ks-dd-state\">menu state: sort="),
        .{ .dynamic = .{ .string = sort_labels[state.dd_sort] } },
        .text(", details="),
        .{ .dynamic = .{ .string = if (state.dd_details) "on" else "off" } },
        .text("</p></section>"),
    });
}

fn sectionTable(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) !void {
    // The full countries feature set (sort, pagination, page-size switch,
    // master-detail) via the shared builder; same layout wrapper as
    // view:countries so both pages render identically.
    try body.append(a, .text("<section><h2>Table</h2>"));
    const parts = try countries.buildCountriesParts(a, .{
        .col = state.sort_col,
        .asc = state.sort_asc,
    }, state.page, state.page_size, state.selected);
    try body.append(a, .text("<div class=\"layout\"><div class=\"tbl-wrap\">"));
    try body.appendSlice(a, parts.table);
    try body.appendSlice(a, parts.controls);
    try body.append(a, .text("</div>"));
    try body.append(a, parts.detail);
    try body.append(a, .text("</div></section>"));
}

// The Card in composition: a Grid of two cards. The first has every slot
// populated — a header with an action (shadcn's CardAction, an icon Button),
// a Stack body (paragraph, labelled Separator, Cluster of buttons) and a
// footer — and the second is the compact `size = sm` variant with no footer.
// Every slot is a plain segment list, and nothing here reads server state,
// so the section renders once at mount and contributes no patch to any later
// update. That is the property the unit test and the e2e check assert, and
// it is why a layout-only change costs one diff slot, not a subtree rewrite.
//
// Container is deliberately absent: the page shell already constrains width.
fn sectionCard(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment)) !void {
    try body.append(a, .text("<section><h2>Card</h2>"));

    // The header action: shadcn's CardAction is usually an icon Button.
    var action: std.ArrayListUnmanaged(view.Segment) = .empty;
    try action.appendSlice(a, try view.Button.render(a, .{
        .label = "&#8942;",
        .variant = .ghost,
        .size = .@"icon-sm",
        .on_click = "inc",
        .aria_label = "Card actions",
    }));

    var actions: std.ArrayListUnmanaged(view.Segment) = .empty;
    try actions.appendSlice(a, try view.Button.render(a, .{
        .label = "Bump count",
        .size = .sm,
        .on_click = "inc",
    }));
    try actions.appendSlice(a, try view.Button.render(a, .{
        .label = "Show flash",
        .variant = .secondary,
        .size = .sm,
        .on_click = "flash",
        .payload = "{\"message\":\"From the card\",\"ttl_ms\":3000}",
    }));

    var card_body: std.ArrayListUnmanaged(view.Segment) = .empty;
    try card_body.append(a, .text(
        "<p>The body is one slot. Here it is a Stack: a paragraph, a " ++
            "labelled Separator, and a Cluster of buttons.</p>",
    ));
    try card_body.appendSlice(a, try view.Separator.render(a, .{ .label = "actions" }));
    try card_body.appendSlice(a, try view.Cluster.render(a, .{
        .gap = .sm,
        .children = actions.items,
    }));

    // The footer must be arena-owned: slots are borrowed by reference (the
    // generated render stores the slice, it does not copy), so a stack array
    // here would dangle as soon as this function returned.
    const footer = try a.dupe(view.Segment, &.{.text(
        "The footer is optional: plain segments after the body. Cards are " ++
            "pure, so an unchanged card emits no patch.",
    )});

    var cards: std.ArrayListUnmanaged(view.Segment) = .empty;
    try cards.appendSlice(a, try view.Card.render(a, .{
        .id = "ks-card-demo",
        .title = "Slots, all the way down",
        .description = "A header, a body that takes anything, and an optional footer.",
        .action = action.items,
        .children = try view.Stack.render(a, .{
            .gap = .sm,
            .children = card_body.items,
        }),
        .footer = footer,
    }));
    try cards.appendSlice(a, try view.Card.render(a, .{
        .id = "ks-card-sm",
        .title = "Compact",
        .description = "The size = sm variant: less padding, tighter gap.",
        .size = .sm,
        .children = try a.dupe(view.Segment, &.{
            .text("<p>Same slots, same purity, one prop different — so " ++
                "switching size is a single patch on the card element.</p>"),
        }),
    }));

    try body.appendSlice(a, try view.Grid.render(a, .{
        .cols = .two,
        .gap = .md,
        .children = cards.items,
    }));

    try body.append(a, .text("</section>"));
}

fn finishTree(a: std.mem.Allocator, body: *std.ArrayListUnmanaged(view.Segment), state: *State) ![]const view.Segment {
    // Sections wrapped in one children node + portaled overlays appended
    // only when open. Every overlay root carries a stable id so morphdom's
    // keyed matching inserts it as a new node (firing onNodeAdded, which
    // mounts the hook) and removes it on close.
    var tree: std.ArrayListUnmanaged(view.Segment) = .empty;
    try tree.append(a, .{ .children = try body.toOwnedSlice(a) });
    if (state.dialog_open) {
        var dialog_children: std.ArrayListUnmanaged(view.Segment) = .empty;
        try dialog_children.appendSlice(a, &.{
            .text("<p>Every component on one page.</p>"),
            .text("<p>Focus is trapped here until you close the dialog.</p>"),
        });
        const dialog = try view.Dialog.render(a, .{
            .id = "ks-dialog",
            .title = "Kitchen sink dialog",
            .children = dialog_children.items,
        });
        try tree.append(a, .{ .children = dialog });
    }
    if (state.dropdown_open) {
        // The full shadcn row taxonomy on one menu: label, plain rows with
        // shortcuts, a checkbox row, a radio group, an inset row, a
        // destructive row, a disabled row and a submenu. The checked states
        // and the open submenu come from server state above, so this
        // re-renders as patches like everything else.
        const share_items = try a.dupe(view.Dropdown.Item, &.{
            .{ .label = "Email", .event = "ks_share", .value = "email" },
            .{ .label = "Copy link", .event = "ks_share", .value = "link", .shortcut = "⌘C" },
            .{ .kind = .separator },
            .{ .label = "Reveal in Finder", .event = "ks_share", .value = "reveal", .disabled = true },
        });
        const items = try a.dupe(view.Dropdown.Item, &.{
            .{ .kind = .label, .label = "Actions" },
            .{ .label = "Bump count by 10", .event = "ks_action", .value = "bump", .shortcut = "⌘B" },
            .{ .label = "Reset count", .event = "ks_action", .value = "reset", .shortcut = "⌘R" },
            .{ .kind = .separator },
            .{ .kind = .checkbox, .label = "Show details", .event = "ks_dd_details", .value = "details", .checked = state.dd_details },
            .{ .kind = .separator },
            .{ .kind = .label, .label = "Sort by" },
            .{ .kind = .radio, .label = "Name", .event = "ks_dd_sort", .value = "0", .checked = state.dd_sort == 0 },
            .{ .kind = .radio, .label = "Size", .event = "ks_dd_sort", .value = "1", .checked = state.dd_sort == 1 },
            .{ .kind = .radio, .label = "Date", .event = "ks_dd_sort", .value = "2", .checked = state.dd_sort == 2 },
            .{ .kind = .separator },
            .{ .kind = .sub, .label = "Share", .value = "share", .sub = share_items },
            .{ .kind = .item, .label = "Delete…", .event = "ks_share", .value = "delete", .variant = .destructive, .inset = true },
        });
        try tree.append(a, .{ .children = try view.DropdownPanel.render(a, .{
            .id = "ks-dd-trigger",
            .items = items,
            .placement = "bottom-start",
            .open_sub = state.dd_sub_open,
        }) });
    }
    // The popover's panel goes last (see below), so that adding and removing
    // it does not shift the tooltips' root indices.
    var popover_panel: ?view.Segment = null;
    if (state.popover_open) {
        const pop_body = try a.dupe(view.Segment, &.{
            .text("<p>A popover with arbitrary content, positioned by Floating UI.</p>"),
        });
        // Popover.render returns [trigger segments..., panel node]: the panel
        // is the last element. (Taking `popover[1]` here — as this view used
        // to — appends one *dynamic* segment instead, which renders the
        // anchor id as stray text and never shows the panel.)
        const popover = try view.Popover.render(a, .{
            .id = "ks-pop-trigger", // anchor: the trigger button
            .label = "About",
            .open = true,
            .children = pop_body,
            .placement = "top",
        });
        popover_panel = popover[popover.len - 1];
    }
    // Tooltips (state-free, always rendered; stable ids for morphdom).
    try tree.append(a, .{ .children = try view.Tooltip.render(a, .{
        .anchor = "ks-tip-anchor",
        .text = "A tooltip: no server state at all",
        .placement = "top",
    }) });
    try tree.append(a, .{ .children = try view.Tooltip.render(a, .{
        .anchor = "ks-tip2-anchor",
        .text = "Second tooltip instance",
        .placement = "bottom",
    }) });
    if (popover_panel) |panel| try tree.append(a, panel);

    const out = try tree.toOwnedSlice(a);
    state.trees[state.active] = out;
    return out;
}

test "card section: the primitives compose, and an unchanged section diffs empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var first: std.ArrayListUnmanaged(view.Segment) = .empty;
    try sectionCard(a, &first);
    const tree = try first.toOwnedSlice(a);

    try std.testing.expectEqualStrings(
        "<section><h2>Card</h2>" ++
            "<div class=\"zc-grid zc-cols-two zc-gap-md\">" ++
            // card 1: every slot populated, including the header action
            "<div class=\"zc-card\" data-slot=\"card\" data-size=\"default\" id=\"ks-card-demo\">" ++
            "<div class=\"zc-card-header\" data-slot=\"card-header\">" ++
            "<div class=\"zc-card-title\" data-slot=\"card-title\">Slots, all the way down</div>" ++
            "<div class=\"zc-card-desc\" data-slot=\"card-description\">A header, a body that takes anything, " ++
            "and an optional footer.</div>" ++
            "<div class=\"zc-card-action\" data-slot=\"card-action\">" ++
            "<button type=\"button\" data-slot=\"button\" data-variant=\"ghost\" data-size=\"icon-sm\" " ++
            "class=\"btn\" data-lv-click=\"inc\" aria-label=\"Card actions\">&#8942;</button></div></div>" ++
            "<div class=\"zc-card-content\" data-slot=\"card-content\">" ++
            "<div class=\"zc-stack zc-gap-sm zc-align-stretch\">" ++
            "<p>The body is one slot. Here it is a Stack: a paragraph, a " ++
            "labelled Separator, and a Cluster of buttons.</p>" ++
            "<div class=\"zc-sep\" role=\"separator\" aria-orientation=\"horizontal\">" ++
            "<span>actions</span></div>" ++
            "<div class=\"zc-cluster zc-gap-sm zc-justify-start\">" ++
            "<button type=\"button\" data-slot=\"button\" data-variant=\"default\" data-size=\"sm\" " ++
            "class=\"btn\" data-lv-click=\"inc\">Bump count</button>" ++
            "<button type=\"button\" data-slot=\"button\" data-variant=\"secondary\" data-size=\"sm\" " ++
            "class=\"btn\" data-lv-click=\"flash\" " ++
            "data-lv-payload='{\"message\":\"From the card\",\"ttl_ms\":3000}'>" ++
            "Show flash</button></div></div></div>" ++
            "<div class=\"zc-card-footer\" data-slot=\"card-footer\">The footer is optional: plain segments " ++
            "after the body. Cards are pure, so an unchanged card emits no patch.</div></div>" ++
            // card 2: the compact size, no footer
            "<div class=\"zc-card\" data-slot=\"card\" data-size=\"sm\" id=\"ks-card-sm\">" ++
            "<div class=\"zc-card-header\" data-slot=\"card-header\">" ++
            "<div class=\"zc-card-title\" data-slot=\"card-title\">Compact</div>" ++
            "<div class=\"zc-card-desc\" data-slot=\"card-description\">The size = sm variant: " ++
            "less padding, tighter gap.</div></div>" ++
            "<div class=\"zc-card-content\" data-slot=\"card-content\">" ++
            "<p>Same slots, same purity, one prop different — so switching size is a single patch " ++
            "on the card element.</p></div></div></div></section>",
        try view.flattenHtml(a, tree),
    );

    // The section reads no server state, so re-rendering it — which is what
    // every kitchen event does — must produce no patches at all. This is the
    // unit-level version of the e2e check; it fails the moment someone hangs
    // a dynamic slot off the card.
    var second: std.ArrayListUnmanaged(view.Segment) = .empty;
    try sectionCard(a, &second);
    var patches = try view.diff(a, tree, try second.toOwnedSlice(a));
    defer patches.deinit();
    try std.testing.expectEqual(@as(usize, 0), patches.count());
}
