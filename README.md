# zlive-examples

The demo app for the zlive framework — and deliberately **only plumbing**:
it names an app context, lists the pages and assets it serves, and wires
the framework's server to a connection handler whose views live in
`src/views/`. It has no HTTP, WebSocket, or protocol dependency of its own.

Sibling packages (consumed as path dependencies):

- `../zlive` — framework **and transport**: segment-tree engine, diff,
  protocol, client runtime, the layout engine (`zlive.layout`),
  `zlive.http.Server` / `Service` / `Slots`, the scoped state store, the
  notification queues, the session registry, static serving
- `../zlive-components` — UI component library (module `zlive_components`),
  hooks.js, zc.css

## Versions

- **Zig 0.17.0**
- Client: morphdom + Floating UI via CDN (loaded by the HTML pages)
- http.zig is **not** a dependency here; zlive owns it

## Run

```sh
zig build run
# info(ziggy): serving zlive demo on http://127.0.0.1:9224
```

Pages: `/` (kitchen sink), `/counter`, `/table`, `/form`, `/tabs`,
`/countries`, `/room`, `/sidebar`, `/themes`, plus the dev-only
`/test-*.html` probes. **Everything is served from memory**: the rendered
pages and `theme.js` are embedded with `@embedFile`, and the client runtime,
component hooks and stylesheet are embedded in the zlive / zlive-components
packages. No directory is read at runtime, so the binary can run from
anywhere and unregistered paths answer 404.

## Page templates

A page is an inheritance template, not a document. `src/templates/base.html`
has the document shell (doctype, head, title block, body/scripts blocks);
`app.html` extends it into a live page (`/zc.css`, `#lv`/`#log`, the client
scripts, and `page`/`page_script`/`vendor`/`head_extra` blocks). A page writes
only what differs:

```html
{% extends "app.html" %}

{% block title %}ziggy view:tabs{% endblock %}

{% block page %}
<h1>view:tabs — zero hooks</h1>
...
{% endblock %}

{% block page_script %}
<script>Live.start({ container: 'lv', log: 'log', topic: 'view:tabs' });</script>
{% endblock %}
```

The framework's engine (`zlive.layout`) implements `extends`, `block`,
`{{ super() }}`, `include`, and `{%- -%}` trimming; there are no expressions,
loops or variables, because per-session content is a view's job. Text outside
blocks in a child is ignored (Jinja's rule), and a block that no parent
defines is a build error.

`src/render_pages.zig` runs the engine at build time and writes
`src/pages_rendered/` (generated — edit the sources, not this directory);
`src/pages.zig` embeds those files. The app owns the renderer (it embeds the
sources, so the build tracks them); the framework's
`zlive.build.addRenderedPages` runs it and copies the output. A template
error fails `zig build` with the template name, line and reason.

## Production build

`zig build` defaults to Debug. For a deployment build, pick an optimize mode:

```sh
# fastest; no runtime safety checks (use once the app is proven)
zig build -Doptimize=ReleaseFast

# keeps safety checks in production (recommended default here)
zig build -Doptimize=ReleaseSafe

# smallest binary
zig build -Doptimize=ReleaseSmall
```

The binary lands at `zig-out/bin/ziggy`. To stage a clean deployment tree,
build into a prefix of your choosing:

```sh
zig build -Doptimize=ReleaseFast --prefix /srv/ziggy
# -> /srv/ziggy/bin/ziggy
```

Cross-compile the same way; the result is a static binary, no runtime
dependencies:

```sh
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-musl --prefix dist
# dist/bin/ziggy: ELF 64-bit LSB executable, ARM aarch64, statically linked
```

### Deploy layout

The binary is self-contained — every page and asset is embedded at compile
time — so there is no layout to get right and no working directory to run
from:

```sh
/srv/ziggy/bin/ziggy
# info(ziggy): listening on http://127.0.0.1:9224 (websocket at /ws)
```

Pages live as templates in `src/pages/` (extending `src/templates/`), are
rendered at build time into `src/pages_rendered/`, and are pulled in with
`@embedFile`:

```zig
// src/pages.zig
.{ .path = "/tabs", .file = "tabs.html", .bytes = @embedFile("pages_rendered/tabs.html") },
```

Edit the templates and rebuild (`file` only names the content type; the route
is `path`). `@embedFile` is bounded by the module root, which is why the
rendered pages live under `src/` rather than in a top-level `static/`. The
build tracks the templates and the render tool, so editing a layout or a page
triggers a rebuild and re-render.

An app that wants to serve markup from disk instead — useful while
iterating, with no rebuild — can set `Config.static` and leave a page's
`bytes` null; the framework still supports both, and the demo uses neither
at runtime.

### Current limits

- The **listen address is compile-time** (`zlive.http.server.default_port`,
  loopback only). Changing it means changing that constant — there is no
  flag or environment override yet.
- There is **no TLS** (terminate it in front) and no container/unit files in
  the repo; the binary is a plain foreground process with SIGINT/SIGTERM
  graceful shutdown.
- Verify a release build the same way as a debug one: start it, then run
  `python3 scripts/e2e.py` (78 checks). `ReleaseFast` and `ReleaseSafe` builds
  were verified this way (all 78 checks, clean shutdown, no leaks) on
  2026-10-15.

## Test

All tests run here, on top of the examples app:

```sh
zig build test   # zlive (engine, protocol, compiler, transport, slots,
                 # session) + zlive-components + app modules
python3 scripts/e2e.py   # 193 end-to-end checks against a running server
```

For e2e, start the server first (`zig build run` or
`./zig-out/bin/ziggy`), then run the script.

## Layout

- `src/main.zig` — the app context (`App`: allocator, io, session registry,
  lock) and the server configuration: pages, embedded assets, `/ws`
- `src/page_manifest.zig` — the page entry names, shared by `build.zig` and
  the render tool
- `src/templates/*.html` — the two parent layouts and the Floating UI
  include: `base.html` (document) and `app.html` (live page)
- `src/pages/*.html` — the page sources (layout + blocks), plus `theme.js`
- `src/render_pages.zig` — the build-time renderer: it feeds these sources to
  `zlive.layout`, and `zlive.build.addRenderedPages` copies the output to
  `src/pages_rendered/`
- `src/pages.zig` + `src/pages_rendered/*.html` — routes and the rendered
  pages embedded with `@embedFile` (under `src/` because that is the module
  root `@embedFile` is bounded by)
- `src/handler.zig` — the connection handler: topic dispatch, and the view
  slots (the framework's `Slots` registry) the views operate on
- `src/notify.zig` — the app's two notification queues: the inline banner
  (`Queue(App, Flash.Props, 1)`) and the corner stack
  (`Queue(App, Toast.Props, 3)`)
- `src/views/*.zig` — one module per demo view (counter, table, form,
  tabs, countries, kitchen sink, room, sidebar, themes)
- `src/views/room.zig` — the scoped-state demo: session-scoped local panel,
  group-scoped room counters, process-wide totals. Open
  `/room?room=x` in two tabs to watch one tab's click patch the other
- `src/views/sidebar.zig` — shadcn's `sidebar-07` block: a team switcher,
  the Platform nav with collapsible sub-menus, a Projects group and a user
  menu, all from the component library's sidebar primitives. The frame is
  the library's `SidebarLayout` + `SiteHeader` components, configured by
  props the Layout popover exposes as selectable options (`mini` sidebar
  on/off, header placement inset/full, sticky header on/off, side, variant). The sidebar's open state is
  server state, so collapsing it is one patch; the page keeps it in a cookie
  the way shadcn does. In the icon rail a nav row opens its sub-items in a
  popup menu beside the rail (same click, same event — the server knows the
  mode), and the popup marks the current page
- `src/views/themes.zig` — the theme gallery at `/themes`: a card per theme in
  shadcn's registry, each one a wrapper carrying `data-base`/`data-accent`, so
  the components inside it are coloured by that palette. Deliberately
  stateless — a theme is client state (`pages/theme.js`), so the picker's
  buttons are inline `onclick` and nothing reaches the patch stream
- `src/view.zig` — facade re-exporting zlive + zlive_components so views
  use a single import
- `src/countries_data.zig` — the 250-country dataset

## License

BSD 3-Clause License — see [LICENSE](LICENSE).
