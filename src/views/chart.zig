// view:chart — live charts (Apache ECharts) fed by a server-side ticker.
//
// The view is only its business logic: the random walk, the spec builders,
// the render. Mount, the patch loop and the ticker thread come from
// zlive.http.Live (ADR-024). Two patterns meet here:
//
//  - the Chart component (zlive-components): the view renders the ECharts
//    option JSON into the data-lv-chart attribute and the zc-chart hook
//    owns the canvas — the element carries data-lv-ignore, so morphdom
//    morphs the attribute but never touches the DOM ECharts drew (ADR-023).
//    A tick is therefore exactly one attribute patch per chart.
//
//  - the ticker: Live's detached thread (same shape as the notification
//    reaper, zlive/src/notify.zig) sleeps, takes the app lock, advances the
//    series and pushes the patch.
//
// Four charts read one random walk: the line and bar charts show the
// window, the gauge shows the latest value, the pie shows the window's
// distribution — four ways to slice the same data, one patch each.

const std = @import("std");
const zlive = @import("zlive");
const protocol = zlive.protocol;
const view = @import("view");
const Handler = @import("handler").Handler;
const App = @import("main").App;

/// Points in the visible window; a tick shifts the window left by one.
const window = 30;
/// Points the view seeds itself with, so the first render is not empty.
const seed_points = 8;

const State = struct {
    rng: std.Random.DefaultPrng,
    last: i64 = 50,
    values: [window]i64 = undefined,
    len: usize = 0,

    pub fn init(_: std.mem.Allocator) State {
        return .{
            .rng = std.Random.DefaultPrng.init(@bitCast(App.nowMs())),
        };
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

fn render(_: *Handler, m: *State, a: std.mem.Allocator) ![]const view.Segment {
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
    return tree;
}

/// Seed the window so the first render is not empty.
fn onMount(_: *Handler, m: *State, _: *const protocol.Envelope) !void {
    while (m.len < seed_points) m.advance();
}

fn onTick(_: *Handler, m: *State) void {
    m.advance();
}

pub const api = zlive.http.Live(App, .{
    .topic = "view:chart",
    .State = State,
    .render = render,
    .onMount = onMount,
    .tick_ms = 1000,
    .onTick = onTick,
});

// The uniform surface the handler's dispatch registry routes by.
pub const topic = api.topic;
pub const handle = api.handle;

// ---------------------------------------------------------------------
// Tests: the spec builders and the window, without a socket.
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

    for (0..500) |_| state.advance();
    for (state.values[0..state.len]) |v| {
        try testing.expect(v >= 5 and v <= 95);
    }
}

test "a tick is one spec-attribute patch per chart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = State.init(testing.allocator);
    // render ignores the handler; the arena keeps both trees alive, which
    // is all the diff needs.
    var dummy: Handler = undefined;
    while (state.len < seed_points) state.advance();
    const previous = try render(&dummy, &state, a);
    state.advance();
    const current = try render(&dummy, &state, a);

    var patches = try view.diff(a, previous, current);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 4), patches.count());
    for (0..4) |i| {
        const spec = patches.at(i).node.dynamic.string;
        try testing.expect(std.mem.startsWith(u8, spec, "{\"animation\":false"));
    }
}
