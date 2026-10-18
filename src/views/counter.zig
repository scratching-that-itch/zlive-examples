const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const util = @import("zlive").util;
const Handler = @import("handler").Handler;

const log = std.log.scoped(.ziggy);

pub const topic = "view:counter";

// Index of the banner slot in the counter view tree.
const banner_slot = 3;

pub const State = struct {
    count: i64 = 0,
    // ping-pong render buffers: diff needs the previous and current
    // trees alive at the same time
    buffers: [2][banner_slot + 1]view.Segment = undefined,
    // ping-pong arenas backing the banner subtree (template-generated
    // components allocate)
    banner_arenas: [2]std.heap.ArenaAllocator,
    active: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .banner_arenas = .{
            std.heap.ArenaAllocator.init(allocator),
            std.heap.ArenaAllocator.init(allocator),
        } };
    }

    pub fn deinit(self: *State) void {
        self.banner_arenas[0].deinit();
        self.banner_arenas[1].deinit();
    }

    fn current(self: *const State) []const view.Segment {
        return &self.buffers[self.active];
    }

    /// Renders the view from its state: the counter, and whatever the banner
    /// queue is holding. The queue is the source of truth for the banner —
    /// showing one and letting one expire are the same kind of state change,
    /// so this needs no notion of a "generation" or of which slot a timer
    /// emptied (see zlive/src/notify.zig).
    ///
    /// Caller holds the app lock: the queue's items are borrowed.
    fn reRender(self: *State, h: *Handler) ![]const view.Segment {
        self.active = 1 - self.active;
        const a = self.active;
        self.buffers[a][0] = .text("<p>count: <button type=\"button\" data-lv-click=\"inc\">+</button> <span data-lv-hook=\"demo\">");
        self.buffers[a][1] = .of(self.count);
        self.buffers[a][2] = .text("</span></p>");
        var arena = &self.banner_arenas[a];
        _ = arena.reset(.retain_capacity);
        const a2 = arena.allocator();
        var banner: std.ArrayListUnmanaged(view.Segment) = .empty;
        for ((try h.bannerQueue()).items()) |item| {
            try banner.appendSlice(a2, try view.Flash.render(a2, item.props));
        }
        self.buffers[a][banner_slot] = .{ .children = try banner.toOwnedSlice(a2) };
        return &self.buffers[a];
    }
};

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mount(h, aa, env);
    }
    _ = h.counter() orelse return h.sendErr(aa, env, "not_joined");
    if (std.mem.eql(u8, env.event, "inc")) {
        return increment(h, aa, env);
    }
    if (std.mem.eql(u8, env.event, "flash")) {
        const message = util.payloadString(env.payload, "message") orelse
            return h.sendErr(aa, env, "malformed");
        const ttl: u64 = @intCast(@min(util.payloadInt(env.payload, "ttl_ms") orelse 4000, 60_000));
        _ = try h.showBanner(message, .info, ttl);
        return pushUpdate(h, aa, env.ref);
    }
    return h.sendErr(aa, env, "unknown_event");
}

/// The queue's reaper calls this when a banner expires: re-render and push
/// the patch, exactly as an event would. It runs with the app lock already
/// held (the reaper holds it), from the reaper's thread.
pub fn flush(h: *Handler) void {
    if (h.counter() == null) return; // this session is not showing the counter
    var arena = std.heap.ArenaAllocator.init(h.app().allocator);
    defer arena.deinit();
    pushUpdate(h, arena.allocator(), null) catch |err| {
        log.warn("counter flush failed: {t}", .{err});
    };
}

fn mount(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (util.sessionToken(env.payload)) |token| {
        try h.adoptToken(token);
        if (h.counter() == null) {
            if (h.app().restore(token)) |saved| {
                const restored = try h.ensure("counter", State, State.init);
                restored.count = saved.count;
                log.info("restored disconnected view (count={d})", .{saved.count});
            }
        }
    }
    const m = try h.ensure("counter", State, State.init);
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const tree = try m.reRender(h);
        log.info("mounted {s} (count={d})", .{ topic, m.count });
        const render = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "render",
            .payload = try view.treeToValue(aa, tree),
            .ref = env.ref,
        };
        // encode copies all borrowed strings; the write below happens
        // after the lock is released
        break :blk try render.encode(aa);
    };
    try h.service.conn.write(json);
}

fn increment(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const m = h.counter() orelse return h.sendErr(aa, env, "not_joined");
    m.count += 1;
    log.info("inc -> count={d}", .{m.count});
    return pushUpdate(h, aa, env.ref);
}

fn pushUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const m = h.counter().?;
    // Lock held from render through encode: the banner queue's items are
    // read here and its reaper frees them under the same lock.
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const previous = m.current();
        const current = try m.reRender(h);
        var patches = try view.diff(aa, previous, current);
        defer patches.deinit();
        log.info("pushing {d} patch(es)", .{patches.count()});
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
