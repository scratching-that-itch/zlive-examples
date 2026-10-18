/* ziggy theming - shadcn's palettes plus a persisted dark mode.
 *
 * Pattern: the theme lives on document.documentElement, OUTSIDE the #lv
 * container that morphdom rewrites on every patch - so morphing can never
 * reset it, and a theme change is not a server roundtrip. Three attributes:
 *
 *   data-theme="light|dark"   the mode
 *   data-base="<base>"        one of shadcn's seven base colors (a full
 *                             token set; `neutral` is the stylesheet default)
 *   data-accent="<accent>"    one of shadcn's seventeen accent themes, which
 *                             override primary/secondary/chart/sidebar-primary
 *                             on top of the base
 *
 * The values are the attribute values in zc.css; the names come from shadcn's
 * own registry (see zlive-components/scripts/gen_themes.py). Both attributes
 * also work on any *element*, which is how /themes previews every palette at
 * once - so the same API can scope a theme to a subtree.
 *
 * The list of names is deliberately not repeated here: a picker's markup is
 * server-rendered from the generated theme list, and this file only reads and
 * writes the attributes.
 */
(function () {
  'use strict';

  const MODE_KEY = 'ziggy.theme';
  const BASE_KEY = 'ziggy.base';
  const ACCENT_KEY = 'ziggy.accent';
  const root = document.documentElement;

  function store(key, value) {
    try {
      if (value) localStorage.setItem(key, value);
      else localStorage.removeItem(key);
    } catch { /* private mode: the theme just will not persist */ }
  }

  function read(key) {
    try { return localStorage.getItem(key); } catch { return null; }
  }

  function state() {
    return {
      mode: root.dataset.theme === 'dark' ? 'dark' : 'light',
      base: root.dataset.base || '',
      accent: root.dataset.accent || '',
    };
  }

  // Every change goes through here, so the attributes, the storage and the
  // event a picker listens to can never disagree.
  function announced() {
    window.dispatchEvent(new CustomEvent('zc-theme', { detail: state() }));
  }

  function setMode(mode) {
    root.dataset.theme = mode === 'dark' ? 'dark' : 'light';
    store(MODE_KEY, root.dataset.theme);
    announced();
  }

  function setBase(name) {
    if (name) root.dataset.base = name;
    else delete root.dataset.base;
    store(BASE_KEY, name || '');
    announced();
  }

  function setAccent(name) {
    if (name) root.dataset.accent = name;
    else delete root.dataset.accent;
    store(ACCENT_KEY, name || '');
    announced();
  }

  window.zcTheme = {
    init() {
      let mode = read(MODE_KEY);
      if (mode !== 'light' && mode !== 'dark') {
        mode = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      }
      root.dataset.theme = mode;
      const base = read(BASE_KEY);
      const accent = read(ACCENT_KEY);
      if (base) root.dataset.base = base;
      if (accent) root.dataset.accent = accent;
      announced();
    },
    toggle() { setMode(state().mode === 'dark' ? 'light' : 'dark'); },
    setMode,
    setBase,
    setAccent,
    reset() { setBase(''); setAccent(''); },
    state,
  };

  window.zcTheme.init();
})();
