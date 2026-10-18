// A view that uses all three state scopes at once.
//
//   session  this tab: which room it is in, and its own "details" toggle.
//            Stored in the handler's slot registry; no other session sees it.
//   group    everyone in the same ?room=: the room's click count. Stored in
//            the scoped store under the room id; a change is pushed to every
//            member (see `flush`).
//   global   the whole process: a click total across all rooms. One cell set
//            in the store; a change is pushed to every session.
//
// The page carries the room id into the mount (`Live.start({join: {room}})`)
// so the session is in its group from the first render.

const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:room";

/// Session scope: one `State` per connection, in the handler's slot
/// registry. `deinit` runs when the connection closes (and its allocations
/// are the app allocator's).
pub const State = struct {
    /// The room this session joined. A fixed buffer: the id comes from the
    /// client and never needs to outlive the state, so there is nothing to
    /// free.
    room_buf: [64]u8 = undefined,
    room_len: usize = 0,
    /// Session-scoped UI state: toggled by this tab, invisible to the others.
    show_details: bool = false,
    /// Ping-pong render buffers, as in the other views: diff needs the
    /// previous and the current tree alive at the same time.
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .arenas = .{
            std.heap.ArenaAllocator.init(allocator),
            std.heap.ArenaAllocator.init(allocator),
        } };
    }

    pub fn deinit(self: *State) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }

    pub fn room(self: *const State) []const u8 {
        return self.room_buf[0..self.room_len];
    }

    fn setRoom(self: *State, name: []const u8) void {
        const n = @min(name.len, self.room_buf.len);
        @memcpy(self.room_buf[0..n], name[0..n]);
        self.room_len = n;
    }
};

/// Group scope: one per room id, shared by its members.
pub const RoomState = struct {
    clicks: i64 = 0,

    pub fn init(_: std.mem.Allocator) RoomState {
        return .{};
    }

    pub fn deinit(_: *RoomState) void {}
};

/// Global scope: one for the process.
pub const GlobalState = struct {
    clicks: i64 = 0,

    pub fn init(_: std.mem.Allocator) GlobalState {
        return .{};
    }

    pub fn deinit(_: *GlobalState) void {}
};

const room_key = "state";
const global_key = "total";

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mount(h, aa, env);
    }
    const state = h.room() orelse return h.sendErr(aa, env, "not_joined");
    const event = env.event;

    // Validate before locking: an unknown event must not take the lock it
    // would then have to release twice.
    if (!std.mem.eql(u8, event, "inc") and
        !std.mem.eql(u8, event, "inc_global") and
        !std.mem.eql(u8, event, "reset") and
        !std.mem.eql(u8, event, "panel"))
    {
        return h.sendErr(aa, env, "unknown_event");
    }

    // Every branch below mutates state under the app lock, then lets the
    // diff push the result: no view writes DOM, and no view builds a patch
    // by hand.
    h.app().lock();
    defer h.app().unlock();

    if (std.mem.eql(u8, event, "inc")) {
        // group + global, and tell the other members of this room to
        // re-render (they are flushed below, inside this lock scope)
        const room_state = try roomState(h, state.room());
        const global_state = try globalState(h);
        room_state.clicks += 1;
        global_state.clicks += 1;
        log.info("room {s}: +1 (room {d}, total {d})", .{ state.room(), room_state.clicks, global_state.clicks });
        h.app().store.notifyGroup(state.room(), h);
    } else if (std.mem.eql(u8, event, "inc_global")) {
        const global_state = try globalState(h);
        global_state.clicks += 1;
        h.app().store.notifyAll(h);
    } else if (std.mem.eql(u8, event, "reset")) {
        const room_state = try roomState(h, state.room());
        room_state.clicks = 0;
        h.app().store.notifyGroup(state.room(), h);
    } else if (std.mem.eql(u8, event, "panel")) {
        // Session-scoped: no notification. This is the point of the third
        // scope — a local UI choice must not leak into the room.
        state.show_details = !state.show_details;
    } else {
        state.show_details = !state.show_details;
    }

    return pushUpdate(h, aa, env.ref);
}

/// Called by the scoped store when another session changed a value this
/// session renders. The store holds the app lock for the whole notify loop,
/// so this must not assume it can take it exclusively — `pushUpdate` locks,
/// and the app's lock is recursive (see App.lock).
pub fn flush(h: *Handler) void {
    if (h.room() == null) return; // this session is not showing a room
    var arena = std.heap.ArenaAllocator.init(h.app().allocator);
    defer arena.deinit();
    pushUpdate(h, arena.allocator(), null) catch |err| {
        log.warn("room flush failed: {t}", .{err});
    };
}

fn mount(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const state = try h.ensure("room", State, State.init);
    const requested = util.payloadString(env.payload, "room") orelse "lobby";
    state.setRoom(if (requested.len == 0) "lobby" else requested);

    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        // Attach + join the group: the group is created on the first member
        // and parked (not freed) when the last one leaves.
        _ = try h.app().store.join(h, state.room());
        // A new member changes the count the others render, so tell them.
        // (Closing is the mirror image, and `detach` notifies on its own.)
        h.app().store.notifyGroup(state.room(), h);
        const tree = try render(h, state);
        log.info("mounted {s} (room {s})", .{ topic, state.room() });
        const reply = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "render",
            .payload = try view.treeToValue(aa, tree),
            .ref = env.ref,
        };
        break :blk try reply.encode(aa);
    };
    try h.service.conn.write(json);
}

fn pushUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const state = h.room().?;
    // Lock held from render through encode: the store's notify loop calls
    // this from another session's thread.
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const previous = state.trees[state.active];
        const current = try render(h, state);
        var patches = try view.diff(aa, previous, current);
        defer patches.deinit();
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

/// The group's cells, re-joining if the group was swept (its TTL expired
/// while this session was away).
fn roomState(h: *Handler, room: []const u8) !*RoomState {
    const cells = h.app().store.groupCells(room) orelse try h.app().store.join(h, room);
    return cells.getOrCreate(room_key, RoomState, RoomState.init);
}

fn globalState(h: *Handler) !*GlobalState {
    return h.app().store.global().getOrCreate(global_key, GlobalState, GlobalState.init);
}

fn render(h: *Handler, state: *State) ![]const view.Segment {
    state.active = 1 - state.active;
    var arena = &state.arenas[state.active];
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    const room_state = try roomState(h, state.room());
    const global_state = try globalState(h);
    const member_count: i64 = @intCast(h.app().store.members(state.room()).len);

    var body: std.ArrayListUnmanaged(view.Segment) = .empty;
    try body.appendSlice(a, &.{
        .text("<section><h2>Room</h2><p class=\"room-line\">room: <b>"),
        .{ .dynamic = .{ .string = state.room() } },
        .text("</b> · members: <b>"),
        .{ .dynamic = .{ .int = member_count } },
        .text("</b> · <span class=\"muted\">local panel: "),
        .{ .dynamic = .{ .string = if (state.show_details) "open" else "closed" } },
        .text("</span></p><p class=\"room-counts\">room clicks: <b>"),
        .{ .dynamic = .{ .int = room_state.clicks } },
        .text("</b> · total clicks (global): <b>"),
        .{ .dynamic = .{ .int = global_state.clicks } },
        .text("</b></p>"),
    });

    // Session-scoped: only this tab's render reads `show_details`, and only
    // this tab's diff sees it change.
    if (state.show_details) {
        try body.append(a, .text(
            "<p class=\"room-details\">Session-scoped detail: this paragraph " ++
                "exists only in this tab's tree. The other members never see it.</p>",
        ));
    }

    var controls: std.ArrayListUnmanaged(view.Segment) = .empty;
    try controls.appendSlice(a, try view.Button.render(a, .{
        .label = "+1 in this room",
        .size = .sm,
        .on_click = "inc",
    }));
    try controls.appendSlice(a, try view.Button.render(a, .{
        .label = "+1 globally",
        .variant = .outline,
        .size = .sm,
        .on_click = "inc_global",
    }));
    try controls.appendSlice(a, try view.Button.render(a, .{
        .label = "toggle local panel",
        .variant = .secondary,
        .size = .sm,
        .on_click = "panel",
    }));
    try controls.appendSlice(a, try view.Button.render(a, .{
        .label = "reset room",
        .variant = .destructive,
        .size = .sm,
        .on_click = "reset",
    }));
    try body.appendSlice(a, try view.Cluster.render(a, .{ .gap = .sm, .children = controls.items }));

    try body.append(a, .text("</section>"));

    const tree = try body.toOwnedSlice(a);
    state.trees[state.active] = tree;
    return tree;
}
