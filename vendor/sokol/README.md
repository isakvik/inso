# sokol (pinned)

Only the two modules inso uses: `gfx` and `log`. Everything else in upstream
sokol (app, audio, debugtext, gl, glue, shape, time) is intentionally absent.

## pinned versions

- sokol headers/C sources: `floooh/sokol` commit
  `cf15469d568da3d1dfbb0d0f8b8b1334aa482609` (2025-09-24).
- Odin bindings: generated from the above via `floooh/sokol-odin` commit
  `cbe19d7094df76f7fe2370523cfa25383bac5112` (2025-09-24).

The prebuilt libs in `gfx/` and `log/` were produced from the matching C
sources. All files in this tree are byte-identical to the pinned upstream
commit(s).

## components

- `c/` - the sokol C sources/headers (gfx + log only).
- `gfx/gfx.odin`, `log/log.odin` - generated Odin bindings. The `.odin` files
  are machine-generated (`// machine generated, do not edit`); they are not
  hand-edited in the upstream sokol-odin repo, and we do not hand-edit them
  either. If they need changes, regenerate or upgrade the pin, don't patch.
- `gfx/`, `log/` - prebuilt GL static libs committed for each platform
  (windows x64 + linux x64, debug/release).
- `build_clibs_linux.sh` / `build_clibs_windows.cmd` - rebuild the committed
  libs from `c/` if they go stale or you build with different flags.

## To bump the pin

1. Pick a new `floooh/sokol` commit, run the sokol-odin generation (or take
   the matching `floooh/sokol-odin` commit if it already tracks it).
2. Replace `c/`, `gfx/gfx.odin`, `log/log.odin` with the regenerated files.
3. Rebuild the libs with `build_clibs_linux.sh` / `build_clibs_windows.cmd`.
4. Update this file's pinned hashes.

## Links

- sokol: https://github.com/floooh/sokol
- odin bindings: https://github.com/floooh/sokol-odin