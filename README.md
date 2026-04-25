# pts

Sports scores in your terminal, powered by [Plain Text Sports](https://plaintextsports.com).

![demo](assets/demo.gif)

## Install

Linux/macOS:

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

Without mise, install Zig 0.16.0 first:

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

## Usage

```sh
pts                         # TUI, all sports
pts nba                     # TUI, NBA
pts mlb --plain             # print and exit
pts --date 2026-04-24       # scores for a date
pts nba --date 2026-04-24   # sport + date
pts --url /mlb/2026-04-24/phi-atl
```

## Keys

```text
j/k, arrows       move
h/l, left/right   previous/next day
d/u, space/PgUp   page
enter             open game
o                 open in browser
/                 filter
r                 refresh
a                 toggle auto-refresh
b/esc             back
?                 help
q                 quit
```

## Flags

```text
--date YYYY-MM-DD     open scores for a date
--plain               print text and exit
--refresh <seconds>   auto-refresh interval (default: 15)
--no-cache            disable cache fallback
--color               enable ANSI colors (default)
--no-color            disable ANSI colors
--url <url>           open Plain Text Sports URL/path
--debug               log parser/network details
--version             print version
--help                print help
```

`NO_COLOR=1` also disables colors.

## Homebrew

Release builds include a generated `pts.rb` formula. After a release:

```sh
brew install https://github.com/h0rv/pts/releases/latest/download/pts.rb
```

For a tap, copy that formula into `h0rv/homebrew-tap/Formula/pts.rb`.

## Development

```sh
mise install
mise exec -- zig build test
mise exec -- zig build
```

Useful release checks:

```sh
OPTIMIZE=Debug ./scripts/package-release.sh x86_64-linux
PREFIX=/tmp/pts-install PTS_ARCHIVE_URL="file://$PWD/dist/pts-x86_64-linux.tar.gz" ./scripts/install.sh
/tmp/pts-install/bin/pts --version
```

## Release

Pushing tag `v*` builds:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-macos`
- `aarch64-macos`
- `x86_64-windows`

Release assets also include `SHA256SUMS` and `pts.rb`.

## Notes

- Uses public Plain Text Sports pages.
- Not affiliated with Plain Text Sports.
- Parser is heuristic, not a full HTML parser.
- Cache lives in `$XDG_CACHE_HOME/pts`, `~/.cache/pts`, or `~/Library/Caches/pts`.
- TUI is ANSI-based.
