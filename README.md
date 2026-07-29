# steam-tweak

`steamctl.sh` — a single-file bash tool for making SteamOS behave on a **laptop**.

SteamOS is built around the Steam Deck: boot straight into Game Mode, one screen,
one GPU, close the lid and sleep. On a hybrid laptop with an external monitor,
every one of those defaults is wrong. This script fixes four of them, and does it
**without disabling the read-only rootfs** — nothing here needs
`steamos-readonly disable`, so a SteamOS update can't wipe your changes or fail
to apply.

```
./steamctl.sh          # interactive menu
./steamctl.sh status   # report current state, change nothing
./steamctl.sh help     # full usage
```

## What it does

| | Problem | Fix |
|---|---|---|
| **Boot mode** | Every boot lands in the gamescope Steam UI | Set default login to Desktop, optionally *lock* it so Steam and OS updates can't change it back |
| **GPU** | gamescope picks its own GPU on a hybrid laptop | Pin games to the discrete (or integrated) card — **without** dragging the KDE desktop onto the dGPU and burning battery |
| **Screen** | Game Mode always opens on the internal panel | Pin Steam to any connected display |
| **Lid** | Leaving Game Mode with the lid shut suspends the machine | Never sleep on lid close — both daemons that handle the lid (logind *and* KDE PowerDevil), on AC and battery |

Plus `diag`, which timestamps a baseline and then reports suspends and gamescope
crashes since — for confirming a fix actually held rather than guessing.

## Install

```bash
git clone https://github.com/28allday/steam-tweak.git
cd steam-tweak
chmod +x steamctl.sh
./steamctl.sh
```

No dependencies beyond what SteamOS already ships (`steamosctl`, `systemctl`,
`busctl`, `vulkaninfo`, and `kreadconfig6`/`kwriteconfig6` for the KDE half of
the lid fix). The script refuses to run if `steamosctl` is missing; if the KDE
config tools are absent it skips the PowerDevil half and says so.

## Root

Only `lock`/`unlock` and `lid` need sudo — they install a systemd unit and a
logind drop-in under `/etc`; `lid` also writes `~/.config/powerdevilrc` as your
own user, which doesn't. Boot mode, GPU and screen need **no root at all**:
`steamos-manager` is polkit-authorized for the `deck` user, and the GPU/screen
pins live in `$HOME`.

## Commands

```
./steamctl.sh                interactive menu
./steamctl.sh toggle         flip desktop-boot on/off
./steamctl.sh desktop [x11]  boot to Desktop Mode (wayland by default)
./steamctl.sh lock / unlock  make desktop-boot permanent / undo
./steamctl.sh game           revert: boot back to Game Mode

./steamctl.sh gpu     [status|reset]   pick the GPU gamescope runs games on
./steamctl.sh screen  [status|reset]   pick the display Game Mode opens on
./steamctl.sh lid     awake|suspend|status
./steamctl.sh diag    mark|report
./steamctl.sh status
```

## How it works

Each fix is deliberately the *least invasive* hook available. The reasoning is
commented in full at the top of each section in the script; the short version:

**Boot mode** — `steamosctl set-default-login-mode desktop` is the supported
call, but Steam and OS updates both rewrite it. The optional lock is a oneshot
systemd unit ordered `Before=sddm.service` that rewrites
`/etc/sddm.conf.d/zz-steamos-autologin.conf` on every boot, so whatever changed
it in the meantime is irrelevant by the time SDDM reads it. It deliberately does
**not** touch steamos-manager's own state, so Steam's "Return to Gaming Mode"
still works as a temporary, this-session-only switch.

**GPU** — a systemd *user drop-in scoped to `gamescope-session.service`*, setting
`MESA_VK_DEVICE_SELECT`. The obvious hook, `~/.config/environment.d/`, is wrong:
it applies to the whole session, so pinning the dGPU there puts the KDE desktop
on the discrete card too. Devices are enumerated with the Mesa device-select
layer rather than `lspci`, because that reports exactly the `vendor:device` IDs
the variable accepts and sees the proprietary NVIDIA driver. The choice is
verified afterwards with `vulkaninfo` rather than assumed. The NVIDIA PRIME
offload vars are vendor-gated so selecting AMD doesn't force offload the wrong
way.

**Screen** — SteamOS hardcodes `-O '*',eDP-1` in the middle of
`/usr/lib/steamos/gamescope-session`, a root-owned file on the read-only rootfs
with no env equivalent. But that script calls `gamescope` *unqualified*, so PATH
decides which binary runs: a small wrapper placed ahead of `/usr/bin` (via the
same service drop-in) rewrites the flag and hands off to the real binary. Valve's
script is never touched, so updates can't break it. The wrapper appends a `,*`
wildcard fallback, so unplugging the pinned display still lets Game Mode start.
It lives outside `~/.local/bin` on purpose — typing `gamescope` in a terminal
still gets the stock binary.

**Lid** — leaving Game Mode with the lid shut suspends the laptop. The journal
shows the suspend is requested *before* gamescope's teardown segfault, and no
lid-switch event is logged at all: the lid was already shut, and what changes is
ownership. Game Mode means no Plasma session, so PowerDevil's inhibitor isn't
there; when the gamescope session's own inhibitors drop on exit, logind
re-evaluates the closed lid and applies its policy on the spot.
`HandleLidSwitchDocked=ignore` can't help — it depends on the display detection
that's breaking.

Two daemons decide the lid depending on which session is up, so both are set.
**logind** covers Game Mode and the TTY (`HandleLidSwitchExternalPower` for AC,
`HandleLidSwitch` for battery). **KDE PowerDevil** covers the desktop: it takes a
*block*-mode inhibitor on `handle-lid-switch`, which stops logind acting on the
lid at all, so under Plasma the logind half is inert and PowerDevil decides —
using its own docked check, defeated by the same momentary loss of the display.
Setting only the logind half looks like it worked (logind cheerfully reports
`ignore`) while the laptop carries on suspending. `LidAction=0` ("do nothing") is
written for all three PowerDevil profiles — AC, Battery *and* LowBattery, since
leaving the last one out means the lid quietly starts sleeping the machine again
once the battery runs down. `lid status` reports whoever actually owns the lid,
not whichever setting is easiest to read.

The consequence is deliberate: **a closed lid then never sleeps this machine at
all, bag included**, where it will stay awake and get warm. PowerDevil's separate
critical-battery action is untouched and still fires. `lid suspend` reverts both
halves, deleting the PowerDevil keys rather than writing "sleep" back, so it
returns to whatever SteamOS configured instead of to a guess at stock.

## Files it touches

| Path | Written by | Removed by |
|---|---|---|
| `/etc/systemd/system/force-desktop-boot.service` | `lock` | `unlock` |
| `/etc/sddm.conf.d/zz-steamos-autologin.conf` | the unit above, each boot | steamos-manager reclaims it |
| `/etc/systemd/logind.conf.d/10-steamctl-lid.conf` | `lid awake` | `lid suspend` |
| `~/.config/powerdevilrc` (`LidAction` in AC/Battery/LowBattery) | `lid awake` | `lid suspend` (keys deleted) |
| `~/.config/systemd/user/gamescope-session.service.d/10-steamctl-gpu.conf` | `gpu` | `gpu reset` |
| `~/.config/systemd/user/gamescope-session.service.d/20-steamctl-screen.conf` | `screen` | `screen reset` |
| `~/.local/share/steamctl/bin/gamescope` | `screen` | `screen reset` |
| `~/.config/steamctl/screen`, `~/.config/steamctl/mark` | `screen`, `diag mark` | `screen reset` |

Every change is reversible from the script itself. `status` shows the current
state of all four.

## Tested on

SteamOS 3.x on a hybrid NVIDIA/AMD laptop with an external display. The GPU and
screen logic is vendor-agnostic in principle but has only been exercised on that
hardware — reports welcome.

## Licence

MIT — see [LICENSE](LICENSE).
