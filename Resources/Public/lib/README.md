# Vendored frontend libraries

Offline-first: no CDN at runtime. These files are committed to the repo and
served by `FileMiddleware` from `Resources/Public/lib/`.

| File | Package | Version | sha256 |
| --- | --- | --- | --- |
| `xterm.js` | `@xterm/xterm` | 5.5.0 | `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495` |
| `xterm.css` | `@xterm/xterm` | 5.5.0 | `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6` |
| `xterm-addon-fit.js` | `@xterm/addon-fit` | 0.10.0 | `bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089` |

Pulled from jsDelivr (`https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0` and
`@xterm/addon-fit@0.10.0`); verify with `shasum -a 256 lib/*`.

The UMD bundles expose globals: `window.Terminal` and `window.FitAddon.FitAddon`.

`terminal.js` wires ws<->term by hand (a few lines), so the deprecated
`@xterm/addon-attach` is not vendored.
