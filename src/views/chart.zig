// view:chart — live charts (Apache ECharts) fed by a server-side ticker.
//
// Two patterns meet here:
//
//  - the Chart component (zlive-components): the view renders the ECharts
//    option JSON into the data-lv-chart attribute and the zc-chart hook
//    owns the canvas — the element carries data-lv-ignore, so morphdom
//    morphs the attribute but never touches the DOM ECharts drew. A tick is
//    therefore exactly one attribute patch per chart.
//
//  - the ticker: a detached thread in the shape of the notification
//    reaper (zlive/src/notify.zig) — a refcounted, disarmable Ticker that
//    sleeps, takes the app lock, advances the series, re-renders and pushes
//    the patch. State.deinit (run by the slot teardown, under the app lock)
//    disarms it, so a sleeping ticker can never touch freed view state.
//
// Four charts read one random walk: the line and bar charts show the
// window, the gauge shows the latest value, the pie shows the window's
// distribution — four ways to slice the same data, one patch each.

const std = @import("std");
const protocol = @import("zlive").protocol;
const view = @import("view");
const Handler = @import("handler").Handler;
const App = @import("main").App;

const log = std.log.scoped(.ziggy);

pub const topic = "view:chart";

/// Points in the visible window; a tick shifts the window left by one.
const window = 30;
/// Tick interval, milliseconds.
const interval_ms: u64 = 1000;
/// Points the view seeds itself with, so the first render is not empty.
const seed_points = 8;

/// Live ticker threads, process-wide — the join-in-spirit for a detached
/// thread, exactly like the notification reapers' counter: the app waits
/// for it at shutdown instead of exiting with a ticker's state allocated.
var tickers: std.atomic.Value(usize) = .init(0);

/// Waits (up to `timeout_ms`) for every ticker to exit, and returns whether
/// they all did. Called from App.shutdown, next to the reapers' waitIdle.
pub fn waitIdle(timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (tickers.load(.acquire) != 0) {
        if (waited >= timeout_ms) return false;
        sleepMs(2);
        waited += 2;
    }
    return true;
}

/// The ticking half of the view. Deliberately a separate, refcounted
/// allocation from the slot cell — the slot registry frees the *cell* on
/// close while a ticker may still be sleeping, so the thread's pointer must
/// not be the cell (the same split as a notification queue's Inner).
const Ticker = struct {
    refs: std.atomic.Value(u32),
    /// Disarmed by State.deinit. Read (under the app lock) before the
    /// ticker touches anything else.
    alive: std.atomic.Value(bool),
    app: *App,
    /// Only ever used after the alive check, under the app lock.
    handler: *Handler,

    fn drop(self: *Ticker) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.app.allocator.destroy(self);
    }
};

pub const State = struct {
    rng: std.Random.DefaultPrng,
    last: i64 = 50,
    values: [window]i64 = undefined,
    len: usize = 0,
    // ping-pong arenas/trees: diff needs the previous and current trees
    // alive at the same time
    arenas: [2]std.heap.ArenaAllocator,
    trees: [2][]const view.Segment = .{ &.{}, &.{} },
    active_tree: usize = 0,
    ticker: ?*Ticker = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .rng = std.Random.DefaultPrng.init(@bitCast(App.nowMs())),
            .arenas = .{
                std.heap.ArenaAllocator.init(allocator),
                std.heap.ArenaAllocator.init(allocator),
            },
        };
    }

    pub fn deinit(self: *State) void {
        // Runs from the slot teardown, under the app lock: disarming here is
        // what keeps a sleeping ticker from ever touching this state again.
        if (self.ticker) |t| {
            t.alive.store(false, .release);
            t.drop();
            self.ticker = null;
        }
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }

    /// One step of the random walk: clamped to the chart's y range.
    fn advance(self: *State) void {
        const delta = self.rng.random().intRangeAtMost(i64, -6, 6);
        self.last = std.math.clamp(self.last + delta, 5, 95);
        if (self.len == window) {
            std.mem.copyForwards(i64, self.values[0 .. window - 1], self.values[1..window]);
            self.values[window - 1] = self.last;
        } else {
            self.values[self.len] = self.last;
            self.len += 1;
        }
    }
};

// The ECharts options, hand-rolled: the specs are numbers and fixed
// strings only, so there is nothing to escape. One builder per chart.

fn lineSpec(a: std.mem.Allocator, values: []const i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"animation\":false,\"title\":{\"text\":\"Random walk\",\"textStyle\":{\"fontSize\":13}}" ++
        ",\"grid\":{\"left\":40,\"right\":16,\"top\":40,\"bottom\":28}" ++
        ",\"xAxis\":{\"type\":\"category\",\"boundaryGap\":false,\"data\":[");
    for (values, 0..) |_, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{d}", .{i});
    }
    try out.appendSlice(a, "]},\"yAxis\":{\"type\":\"value\",\"min\":0,\"max\":100}" ++
        ",\"series\":[{\"type\":\"line\",\"showSymbol\":false,\"smooth\":true,\"data\":[");
    for (values, 0..) |v, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{d}", .{v});
    }
    try out.appendSlice(a, "]}]}");
    return out.items;
}

fn barSpec(a: std.mem.Allocator, values: []const i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"animation\":false,\"title\":{\"text\":\"Same window, as bars\",\"textStyle\":{\"fontSize\":13}}" ++
        ",\"grid\":{\"left\":40,\"right\":16,\"top\":40,\"bottom\":28}" ++
        ",\"xAxis\":{\"type\":\"category\",\"data\":[");
    for (values, 0..) |_, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{d}", .{i});
    }
    try out.appendSlice(a, "]},\"yAxis\":{\"type\":\"value\",\"min\":0,\"max\":100}" ++
        ",\"series\":[{\"type\":\"bar\",\"data\":[");
    for (values, 0..) |v, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{d}", .{v});
    }
    try out.appendSlice(a, "]}]}");
    return out.items;
}

fn gaugeSpec(a: std.mem.Allocator, value: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"animation\":false,\"title\":{\"text\":\"Latest value\",\"textStyle\":{\"fontSize\":13}}" ++
        ",\"series\":[{\"type\":\"gauge\",\"min\":0,\"max\":100,\"startAngle\":210,\"endAngle\":-30" ++
        ",\"progress\":{\"show\":true},\"pointer\":{\"show\":false}" ++
        ",\"axisLine\":{\"lineStyle\":{\"width\":14}},\"axisTick\":{\"show\":false}" ++
        ",\"splitLine\":{\"show\":false},\"axisLabel\":{\"show\":false}" ++
        ",\"detail\":{\"valueAnimation\":false,\"fontSize\":24,\"offsetCenter\":[0,\"0%\"],\"formatter\":\"{value}\"}" ++
        ",\"data\":[{\"value\":");
    try out.print(a, "{d}", .{value});
    try out.appendSlice(a, "}]}]}");
    return out.items;
}

fn pieSpec(a: std.mem.Allocator, values: []const i64) ![]const u8 {
    var low: usize = 0;
    var mid: usize = 0;
    var high: usize = 0;
    for (values) |v| {
        if (v < 35) {
            low += 1;
        } else if (v <= 65) {
            mid += 1;
        } else {
            high += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"animation\":false,\"title\":{\"text\":\"Window distribution\",\"textStyle\":{\"fontSize\":13}}" ++
        ",\"tooltip\":{\"trigger\":\"item\"}" ++
        ",\"series\":[{\"type\":\"pie\",\"radius\":[\"40%\",\"70%\"],\"center\":[\"50%\",\"60%\"]" ++
        ",\"label\":{\"fontSize\":11}" ++
        ",\"data\":[{\"name\":\"low (0–34)\",\"value\":");
    try out.print(a, "{d}", .{low});
    try out.appendSlice(a, "},{\"name\":\"mid (35–65)\",\"value\":");
    try out.print(a, "{d}", .{mid});
    try out.appendSlice(a, "},{\"name\":\"high (66–100)\",\"value\":");
    try out.print(a, "{d}", .{high});
    try out.appendSlice(a, "}]}]}");
    return out.items;
}

fn renderTree(m: *State) ![]const view.Segment {
    const next = 1 - m.active_tree;
    _ = m.arenas[next].reset(.retain_capacity);
    const a = m.arenas[next].allocator();
    m.active_tree = next;

    const tree = try a.alloc(view.Segment, 7);
    tree[0] = .text("<p>One random walk, four charts: a server tick every second pushes one spec-attribute patch per chart — the differ never enters a canvas.</p>");
    tree[1] = .text("<div class=\"charts-grid\">");
    tree[2] = .{ .children = try view.Chart.render(a, .{
        .id = "walk",
        .spec = try lineSpec(a, m.values[0..m.len]),
        .height = "260px",
    }) };
    tree[3] = .{ .children = try view.Chart.render(a, .{
        .id = "bars",
        .spec = try barSpec(a, m.values[0..m.len]),
        .height = "260px",
    }) };
    tree[4] = .{ .children = try view.Chart.render(a, .{
        .id = "gauge",
        .spec = try gaugeSpec(a, m.last),
        .height = "260px",
    }) };
    tree[5] = .{ .children = try view.Chart.render(a, .{
        .id = "mix",
        .spec = try pieSpec(a, m.values[0..m.len]),
        .height = "260px",
    }) };
    tree[6] = .text("</div>");
    m.trees[next] = tree;
    return tree;
}

pub fn handle(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    if (std.mem.eql(u8, env.event, "join")) {
        return mount(h, aa, env);
    }
    _ = h.chart() orelse return h.sendErr(aa, env, "not_joined");
    return h.sendErr(aa, env, "unknown_event");
}

fn mount(h: *Handler, aa: std.mem.Allocator, env: *const protocol.Envelope) !void {
    const m = try h.ensure("chart", State, State.init);
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        while (m.len < seed_points) m.advance();
        const tree = try renderTree(m);
        log.info("mounted {s}", .{topic});
        const render = protocol.Envelope{
            .type = .message,
            .topic = topic,
            .event = "render",
            .payload = try view.treeToValue(aa, tree),
            .ref = env.ref,
        };
        break :blk try render.encode(aa);
    };
    try spawnTicker(h, m);
    try h.service.conn.write(json);
}

fn spawnTicker(h: *Handler, m: *State) !void {
    if (m.ticker != null) return; // a rejoin keeps its ticker
    const t = try h.app().allocator.create(Ticker);
    t.* = .{
        // one reference for the state cell, one for the thread
        .refs = .init(2),
        .alive = .init(true),
        .app = h.app(),
        .handler = h,
    };
    m.ticker = t;
    // Counted before the spawn so a concurrent waitIdle cannot see a quiet
    // process between the thread starting and being counted.
    _ = tickers.fetchAdd(1, .release);
    const thread = std.Thread.spawn(.{}, tickerMain, .{t}) catch {
        _ = tickers.fetchSub(1, .release);
        m.ticker = null;
        h.app().allocator.destroy(t);
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

/// The ticker's whole loop: sleep, then under the app lock advance the
/// series and push the patch; between wakeups it holds nothing.
fn tickerMain(t: *Ticker) void {
    // The reference is dropped (and the state freed) before the thread is
    // counted as gone, so a waiter that sees zero can trust that everything
    // a ticker held is released.
    defer {
        t.drop();
        _ = tickers.fetchSub(1, .release);
    }
    while (true) {
        sleepMs(interval_ms);
        t.app.lock();
        if (!t.alive.load(.acquire)) {
            t.app.unlock();
            return;
        }
        tickLocked(t.handler);
        t.app.unlock();
    }
}

/// Runs with the app lock held (the ticker holds it): advance the series
/// and push the patch, exactly as an event would.
fn tickLocked(h: *Handler) void {
    const m = h.chart() orelse return;
    m.advance();
    var arena = std.heap.ArenaAllocator.init(h.app().allocator);
    defer arena.deinit();
    pushUpdate(h, arena.allocator(), null) catch |err| {
        log.warn("chart tick failed: {t}", .{err});
    };
}

fn pushUpdate(h: *Handler, aa: std.mem.Allocator, ref: ?u64) !void {
    const m = h.chart().?;
    // Lock held from render through encode (recursive: the ticker already
    // holds it), so the tree the diff reads cannot change under it.
    h.app().lock();
    const json = blk: {
        defer h.app().unlock();
        const previous = m.trees[m.active_tree];
        const current = try renderTree(m);
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

/// Sleep for `ms`, uninterruptibly — same reasoning as the notification
/// reaper's sleepMs (zlive/src/notify.zig).
fn sleepMs(ms: u64) void {
    var req: std.posix.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.posix.errno(std.posix.system.nanosleep(&req, &req)) == .INTR) {}
}

// ---------------------------------------------------------------------
// Tests: the spec builder and the window, without a socket.
// ---------------------------------------------------------------------

const testing = std.testing;

test "lineSpec is valid JSON carrying every point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spec = try lineSpec(a, &.{ 10, 20, 30 });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, spec, .{});
    const series = parsed.value.object.get("series").?.array.items[0];
    const data = series.object.get("data").?.array.items;
    try testing.expectEqual(@as(usize, 3), data.len);
    try testing.expectEqual(@as(i64, 20), data[1].integer);
}

test "barSpec is valid JSON with one bar per point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spec = try barSpec(a, &.{ 5, 15 });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, spec, .{});
    const series = parsed.value.object.get("series").?.array.items[0];
    try testing.expectEqualStrings("bar", series.object.get("type").?.string);
    try testing.expectEqual(@as(usize, 2), series.object.get("data").?.array.items.len);
}

test "gaugeSpec carries the latest value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spec = try gaugeSpec(a, 42);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, spec, .{});
    const series = parsed.value.object.get("series").?.array.items[0];
    const data = series.object.get("data").?.array.items[0];
    try testing.expectEqual(@as(i64, 42), data.object.get("value").?.integer);
}

test "pieSpec buckets sum to the window length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // two low, two mid, one high
    const spec = try pieSpec(a, &.{ 5, 30, 40, 65, 90 });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, spec, .{});
    const data = parsed.value.object.get("series").?.array.items[0].object.get("data").?.array.items;
    try testing.expectEqual(@as(usize, 3), data.len);
    try testing.expectEqual(@as(i64, 2), data[0].object.get("value").?.integer);
    try testing.expectEqual(@as(i64, 2), data[1].object.get("value").?.integer);
    try testing.expectEqual(@as(i64, 1), data[2].object.get("value").?.integer);
}

test "advance fills the window, then slides it" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    for (0..window) |_| state.advance();
    try testing.expectEqual(@as(usize, window), state.len);

    const second = state.values[1];
    state.advance();
    try testing.expectEqual(@as(usize, window), state.len); // still full
    try testing.expectEqual(second, state.values[0]); // shifted left by one
    try testing.expectEqual(state.last, state.values[window - 1]);
}

test "advance stays inside the chart's y range" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    for (0..500) |_| state.advance();
    for (state.values[0..state.len]) |v| {
        try testing.expect(v >= 5 and v <= 95);
    }
}

test "a tick is one spec-attribute patch per chart" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    while (state.len < seed_points) state.advance();
    _ = try renderTree(&state);
    const previous = state.trees[state.active_tree];
    state.advance();
    const current = try renderTree(&state);

    var patches = try view.diff(a, previous, current);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 4), patches.count());
    for (0..4) |i| {
        const spec = patches.at(i).node.dynamic.string;
        try testing.expect(std.mem.startsWith(u8, spec, "{\"animation\":false"));
    }
}
