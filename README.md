<p align="center">
  <img src="docs/og.png" alt="fuzoo — two time zones in your macOS menu bar" width="640">
</p>

<p align="center">
  <b>Two time zones in your menu bar. ~7 MB of RAM. Nothing else.</b><br>
  <a href="https://oisergiofelix.github.io/fuzoo/">Website</a> ·
  <a href="https://github.com/oisergiofelix/fuzoo/releases/latest/download/fuzoo.dmg">Download for macOS</a> ·
  <a href="README.pt-BR.md">Português</a>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-1a1a1a">
  <img alt="Apple Silicon + Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-1a1a1a">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-ff5a1f">
</p>

---

## Why

I work remotely from Campo Grande, one hour behind São Paulo. Every meeting invite, every deadline, every "talk at 3?" meant doing the math in my head, all day long.

The world-clock apps I found did a lot more than I needed and cost a lot more memory than a clock should. I wanted the opposite: two times in the menu bar, and a process so small I'd forget it was running.

So I built **fuzoo**.

```
CG 16:16  SP 17:16
```

It ships with Campo Grande and São Paulo. Swap them, add more, or rename the labels from the menu.

## How small

| | fuzoo |
|---|---|
| Memory (`phys_footprint`) | **~7.7 MB** |
| CPU | **0%**: wakes once a minute, for microseconds |
| App size | **~100 KB** download, universal binary |
| Dependencies | **none** |
| Source | **1 file**, ~300 lines of Objective-C |

Those ~7 MB are the floor for anything that draws in the macOS menu bar (AppKit plus the WindowServer connection). We measured it: the same clock rewritten in plain C, calling the Objective-C runtime by hand, used *more*. fuzoo's own code accounts for a few kilobytes.

### What keeps it tiny

- **One wake-up per minute.** A wall-clock timer fires exactly when the minute turns, and stays correct across sleep and wake. A 1-second tolerance lets macOS batch it with other work.
- **No date formatters.** The time is plain arithmetic on the zone's UTC offset.
- **Real time zones.** IANA identifiers (`America/Campo_Grande`), so daylight saving and rule changes come from macOS itself.
- **A lazy menu.** It's built only when you click.
- **No frameworks, nibs or helpers.** Just AppKit.

## Install

1. [Download `fuzoo.dmg`](https://github.com/oisergiofelix/fuzoo/releases/latest/download/fuzoo.dmg) and drag **fuzoo** into **Applications**.
2. fuzoo isn't notarized by Apple (yet), so the first launch is blocked. Allow it in one of two ways:
   - **System Settings → Privacy & Security** → scroll down → **Open Anyway**, or
   - in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/fuzoo.app
     ```
3. Click the clock → **Open at login**.

Prefer to build it yourself? You only need the Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/oisergiofelix/fuzoo && cd fuzoo && make install
```

## Use

Click the clock in the menu bar:

- **Each clock** → pick a city, choose **Other time zone…** (any IANA zone), **Rename label…**, or **Remove**
- **Add clock**
- **Open at login**

The interface follows your system language (English or Portuguese).

Prefer the terminal? Edit the clocks directly, then relaunch:

```bash
defaults write io.github.oisergiofelix.fuzoo clocks -array \
  '{label=CG;tz="America/Campo_Grande";}' '{label=SP;tz="America/Sao_Paulo";}'
```

## Develop

```bash
make run       # build and open
make release   # build/fuzoo.dmg + build/fuzoo.zip
make brand     # regenerate icon and images from tools/brand.m
make clean
```

Pushing a `v*` tag builds and publishes a release via GitHub Actions.

Contributions are welcome. One rule: **fuzoo must not get heavier.** If a feature costs memory or wake-ups while the menu is closed, it probably doesn't belong here.

## License

[MIT](LICENSE) © Sérgio Felix
