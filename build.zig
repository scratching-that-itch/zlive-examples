const std = @import("std");
// The framework's build helpers: rendering page layouts (zlive.layout) is a
// framework feature, like compiling component templates.
const zlive_build = @import("zlive");
const page_manifest = @import("src/page_manifest.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The framework owns the transport dependency; this app does not
    // depend on httpz at all.
    const zlive_dep = b.dependency("zlive", .{
        .target = target,
        .optimize = optimize,
    });
    const components_dep = b.dependency("zlive_components", .{
        .target = target,
        .optimize = optimize,
    });

    // Regenerate the component .zig files from their .html templates.
    // The examples app is the root build here, so UpdateSourceFiles needs
    // the components package's path relative to this build root.
    const components_build = @import("zlive_components");
    const templates = components_build.templatesStep(b, zlive_dep, components_dep, "../zlive-components/");

    // App modules with mutual imports (handler <-> views); created as a
    // struct so wiring is comptime, then every module gets every import.
    // "view" is the facade re-exporting the zlive engine + the component
    // library, so view code reads `view.Segment`, `view.Table`, etc.
    const app_modules = .{
        .main = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
        .view = b.createModule(.{ .root_source_file = b.path("src/view.zig"), .target = target, .optimize = optimize }),
        .countries_data = b.createModule(.{ .root_source_file = b.path("src/countries_data.zig"), .target = target, .optimize = optimize }),
        // The demo's HTML pages and theme script, embedded via @embedFile
        // (module-root bounded, which is why they live under src/).
        .pages = b.createModule(.{ .root_source_file = b.path("src/pages.zig"), .target = target, .optimize = optimize }),
        .handler = b.createModule(.{ .root_source_file = b.path("src/handler.zig"), .target = target, .optimize = optimize }),
        .notify = b.createModule(.{ .root_source_file = b.path("src/notify.zig"), .target = target, .optimize = optimize }),
        .counter = b.createModule(.{ .root_source_file = b.path("src/views/counter.zig"), .target = target, .optimize = optimize }),
        .table_demo = b.createModule(.{ .root_source_file = b.path("src/views/table_demo.zig"), .target = target, .optimize = optimize }),
        .form_demo = b.createModule(.{ .root_source_file = b.path("src/views/form_demo.zig"), .target = target, .optimize = optimize }),
        .tabs = b.createModule(.{ .root_source_file = b.path("src/views/tabs.zig"), .target = target, .optimize = optimize }),
        .countries = b.createModule(.{ .root_source_file = b.path("src/views/countries.zig"), .target = target, .optimize = optimize }),
        .detail = b.createModule(.{ .root_source_file = b.path("src/views/detail.zig"), .target = target, .optimize = optimize }),
        .kitchen_sink = b.createModule(.{ .root_source_file = b.path("src/views/kitchen_sink.zig"), .target = target, .optimize = optimize }),
        .room = b.createModule(.{ .root_source_file = b.path("src/views/room.zig"), .target = target, .optimize = optimize }),
        .sidebar = b.createModule(.{ .root_source_file = b.path("src/views/sidebar.zig"), .target = target, .optimize = optimize }),
        .themes = b.createModule(.{ .root_source_file = b.path("src/views/themes.zig"), .target = target, .optimize = optimize }),
    };
    const module_names = @typeInfo(@TypeOf(app_modules)).@"struct".field_names;
    inline for (module_names) |name| {
        const mod = @field(app_modules, name);
        mod.addImport("zlive", zlive_dep.module("zlive"));
        mod.addImport("zlive_components", components_dep.module("zlive_components"));
        inline for (module_names) |dep_name| {
            mod.addImport(dep_name, @field(app_modules, dep_name));
        }
    }

    // Pages are templates too: the server's page table is comptime and bakes
    // each page's bytes into its handler, so a host tool resolves each page's
    // `{% extends %}` chain before anything embeds the result. The renderer
    // uses zlive.layout; the framework's copy step writes the rendered pages
    // to src/pages_rendered/, which src/pages.zig embeds.
    const render_pages_exe = b.addExecutable(.{
        .name = "render-pages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_pages.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "zlive", .module = zlive_dep.module("zlive") },
            },
        }),
    });
    const render_pages = zlive_build.addRenderedPages(
        b,
        render_pages_exe,
        &page_manifest.files,
        "src/pages_rendered/",
    );

    const exe = b.addExecutable(.{
        .name = "ziggy",
        .root_module = app_modules.main,
    });
    exe.step.dependOn(templates);
    exe.step.dependOn(render_pages);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // All tests run here, on top of the examples app: the framework, the
    // component library, and the app's own modules.
    const zlive_tests = b.addTest(.{
        .root_module = zlive_dep.module("zlive"),
    });
    const run_zlive_tests = b.addRunArtifact(zlive_tests);

    const components_tests = b.addTest(.{
        .root_module = components_dep.module("zlive_components"),
    });
    components_tests.step.dependOn(templates);
    const run_components_tests = b.addRunArtifact(components_tests);

    const main_tests = b.addTest(.{
        .root_module = app_modules.main,
    });
    main_tests.step.dependOn(templates);
    main_tests.step.dependOn(render_pages);
    const run_main_tests = b.addRunArtifact(main_tests);

    // The embedded pages: every route present, unique, and non-empty.
    const pages_tests = b.addTest(.{
        .root_module = app_modules.pages,
    });
    pages_tests.step.dependOn(render_pages);
    const run_pages_tests = b.addRunArtifact(pages_tests);

    // The render tool and zlive.layout. The layout engine's tests run in the
    // zlive package; this covers the app's page list against the engine.
    const page_render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_pages.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlive", .module = zlive_dep.module("zlive") },
            },
        }),
    });
    const run_page_render_tests = b.addRunArtifact(page_render_tests);

    // The table view's state/diff regression test.
    const table_tests = b.addTest(.{
        .root_module = app_modules.table_demo,
    });
    table_tests.step.dependOn(templates);
    const run_table_tests = b.addRunArtifact(table_tests);

    // The kitchen sink's card section: composition snapshot + the "purity"
    // property (an unchanged section diffs empty). View modules are not
    // covered by main_tests, so each view with tests needs its own step.
    const kitchen_tests = b.addTest(.{
        .root_module = app_modules.kitchen_sink,
    });
    kitchen_tests.step.dependOn(templates);
    const run_kitchen_tests = b.addRunArtifact(kitchen_tests);

    // The sidebar block's state rules: the one-patch toggle, the collapse
    // modes, the disclosure, and the click-value validation.
    const sidebar_tests = b.addTest(.{
        .root_module = app_modules.sidebar,
    });
    sidebar_tests.step.dependOn(templates);
    const run_sidebar_tests = b.addRunArtifact(sidebar_tests);

    // The theme gallery: every shadcn palette rendered from the generated
    // theme list.
    const themes_tests = b.addTest(.{
        .root_module = app_modules.themes,
    });
    themes_tests.step.dependOn(templates);
    const run_themes_tests = b.addRunArtifact(themes_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_zlive_tests.step);
    test_step.dependOn(&run_components_tests.step);
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_pages_tests.step);
    test_step.dependOn(&run_page_render_tests.step);
    test_step.dependOn(&run_table_tests.step);
    test_step.dependOn(&run_kitchen_tests.step);
    test_step.dependOn(&run_sidebar_tests.step);
    test_step.dependOn(&run_themes_tests.step);
}
