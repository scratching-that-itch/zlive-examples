// view:counter — a button counter with flash banners and rejoin restore.
//
// The view is only its business logic — state, render, event handling.
// Mount, the patch loop and the render arenas come from zlive.http.Live
// (see DECISIONS.md ADR-024).

const std = @import("std");
const zlive = @import("zlive");
const protocol = zlive.protocol;
const util = zlive.util;
const view = @import("view");
const Handler = @import("handler").Handler;
const App = @import("main").App;

const log = std.log.scoped(.ziggy);

const State = struct {
    count: i64 = 0,
};

/// The counter, and whatever the banner queue is holding. The queue is the
/// source of truth for the banner — showing one and letting one expire are
/// the same kind of state change, so this needs no notion of a
/// "generation" (see zlive/src/notify.zig). Runs under the app lock with
/// the framework's render arena.
fn render(h: *Handler, m: *State, a: std.mem.Allocator) ![]const view.Segment {
    var banner: std.ArrayListUnmanaged(view.Segment) = .empty;
    for ((try h.bannerQueue()).items()) |item| {
        try banner.appendSlice(a, try view.Flash.render(a, item.props));
    }
    const tree = try a.alloc(view.Segment, 4);
    tree[0] = .text("<p>count: <button type=\"button\" data-lv-click=\"inc\">+</button> <span data-lv-hook=\"demo\">");
    tree[1] = .of(m.count);
    tree[2] = .text("</span></p>");
    tree[3] = .{ .children = try banner.toOwnedSlice(a) };
    return tree;
}

/// A rejoin within the TTL restores the parked count instead of mounting
/// fresh. Runs on every join; a same-connection rejoin finds nothing
/// parked (only `close` parks), so it is a no-op there.
fn onMount(h: *Handler, m: *State, env: *const protocol.Envelope) !void {
    const token = util.sessionToken(env.payload) orelse return;
    try h.adoptToken(token);
    if (h.app().restore(token)) |saved| {
        m.count = saved.count;
        log.info("restored disconnected view (count={d})", .{saved.count});
    }
}

fn onEvent(h: *Handler, m: *State, aa: std.mem.Allocator, env: *const protocol.Envelope) !zlive.http.EventResult {
    if (std.mem.eql(u8, env.event, "inc")) {
        m.count += 1;
        log.info("inc -> count={d}", .{m.count});
        return .push;
    }
    if (std.mem.eql(u8, env.event, "flash")) {
        const message = util.payloadString(env.payload, "message") orelse {
            try h.sendErr(aa, env, "malformed");
            return .replied;
        };
        const ttl: u64 = @intCast(@min(util.payloadInt(env.payload, "ttl_ms") orelse 4000, 60_000));
        _ = try h.showBanner(message, .info, ttl);
        return .push;
    }
    return .unknown;
}

pub const api = zlive.http.Live(App, .{
    .topic = "view:counter",
    .State = State,
    .render = render,
    .onEvent = onEvent,
    .onMount = onMount,
});

// The uniform surface the handler's dispatch registry routes by.
pub const topic = api.topic;
pub const handle = api.handle;
