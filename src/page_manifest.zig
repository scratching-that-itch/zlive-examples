//! The app's page entry points, in route order.
//!
//! `build.zig` renders each one with the layout renderer, and
//! `render_pages.zig` embeds the sources and tests the same list. Keeping
//! the list in a dependency-free file lets the build script and the render
//! tool share it without the build script importing zlive's render API.

pub const files = [_][]const u8{
    "index.html",
    "counter.html",
    "table.html",
    "form.html",
    "tabs.html",
    "countries.html",
    "room.html",
    "sidebar.html",
    "themes.html",
    "test-morph.html",
    "test-floating.html",
    "test-dd.html",
};
