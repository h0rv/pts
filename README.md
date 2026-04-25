# pts

A sports scores CLI and TUI, powered by [Plain Text Sports](https://plaintextsports.com), written in Zig.

![demo](assets/demo.gif)

## Install

Linux/macOS release install:

```sh
curl -fsSL https://raw.githubusercontent.com/h0rv/pts/main/scripts/install.sh | sh
```

From source:

```sh
git clone https://github.com/h0rv/pts.git
cd pts
mise trust
mise install
mise exec -- zig build -Doptimize=ReleaseFast --prefix ~/.local
pts
```

Without mise, install Zig 0.16.0 and run:

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

## Usage

```sh
pts
pts nba
pts nhl
pts mlb
pts nba schedule
pts nhl standings
pts --plain
pts nba --plain
pts --date 2026-04-24
pts nba --date 2026-04-24 --plain
pts --url /mlb/2026-04-24/phi-atl
```

## Keys

```text
q          quit
j/down     down
k/up       up
d/space    page down
u/PgUp     page up
PgDn       page down
h/left     previous day
l/right    next day
enter      open item
o          open item/page in browser
b/esc      back
r          refresh
/          filter
a          toggle auto refresh
?          help
g          top
G          bottom
```

## Flags

```text
--refresh <seconds>   auto-refresh interval (default: 15)
--no-cache            disable cache fallback
--plain               print text and exit
--debug               log parser/network details
--date YYYY-MM-DD     open scores for a date
--color               enable ANSI colors (default)
--no-color            disable ANSI colors
--url <url>           open Plain Text Sports URL/path
--version             print version
--help                print help
```

## Demo GIF

Uses [VHS](https://github.com/charmbracelet/vhs).

```sh
mise install
./scripts/record-demo.sh
```

Writes `assets/demo.gif`.

## Development

```sh
mise install
mise exec -- zig build test
mise exec -- zig build -Doptimize=ReleaseFast --prefix ~/.local
mise exec -- zig build -Dtarget=x86_64-linux
mise exec -- zig build -Dtarget=aarch64-linux
mise exec -- zig build -Dtarget=x86_64-macos
mise exec -- zig build -Dtarget=aarch64-macos
mise exec -- zig build -Dtarget=x86_64-windows
```

## Releases

Pushing tag `v*` builds GitHub release artifacts for:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-macos`
- `aarch64-macos`
- `x86_64-windows`

## Notes

- Uses Plain Text Sports public pages.
- Not affiliated with Plain Text Sports.
- Parser is heuristic, not a full HTML parser.
- Cache fallback uses `$XDG_CACHE_HOME/pts`, `~/.cache/pts`, or `~/Library/Caches/pts`.
- TUI is ANSI-based. Linux is tested; macOS and Windows cross-compile in CI.
- Set `NO_COLOR=1` or pass `--no-color` to disable ANSI colors.
