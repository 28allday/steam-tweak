#!/usr/bin/env bash
# steamctl.sh — manage Steam on a SteamOS laptop.
#
# Four things so far:
#
# 1. Boot mode. SteamOS decides which session SDDM autologins into via
#    steamos-manager's "default login mode" setting; out of the box it is
#    `game`, so every boot lands in the gamescope Steam UI. This forces
#    `desktop` and can make it permanent against Steam/OS updates changing it.
#
# 2. GPU selection. On a hybrid laptop, picks whether gamescope and games run
#    on the discrete or integrated GPU.
#
# 3. Screen selection. Picks which display Game Mode opens on.
#
# 4. Lid handling. Stops the laptop sleeping when you leave Game Mode with the
#    lid shut and an external monitor attached.
#
# Usage:
#   ./steamctl.sh              interactive menu (boot mode + GPU picker)
#   ./steamctl.sh toggle       flip desktop-boot on/off without the menu
#   ./steamctl.sh desktop      boot to Desktop Mode (no permanent lock)
#   ./steamctl.sh desktop x11  boot to Desktop Mode using the X11 session
#   ./steamctl.sh lock         explicitly turn the lock ON
#   ./steamctl.sh unlock       remove the lock, leave boot mode as-is
#   ./steamctl.sh gpu          pick which GPU gamescope runs games on
#   ./steamctl.sh gpu status   show the pinned GPU
#   ./steamctl.sh gpu reset    unpin, back to stock
#   ./steamctl.sh screen       pick which display Steam/Game Mode opens on
#   ./steamctl.sh screen status  show the pinned screen
#   ./steamctl.sh screen reset   unpin, back to stock
#   ./steamctl.sh lid awake    on AC, don't sleep when the lid closes
#   ./steamctl.sh lid suspend  restore stock lid behaviour
#   ./steamctl.sh lid status   show what logind will do on lid close
#   ./steamctl.sh diag mark    timestamp a baseline before testing Game Mode
#   ./steamctl.sh diag         report suspends/crashes since that baseline
#   ./steamctl.sh status       report current state, change nothing
#   ./steamctl.sh game         revert: boot back to Game Mode
#
# Root: only `lock`/`unlock` need sudo, to install a systemd unit. Setting the
# boot mode and picking a GPU need no root at all — steamos-manager is
# polkit-authorized for `deck`, and the GPU pin lives in $HOME. Nothing here
# requires `steamos-readonly disable`.

set -euo pipefail

readonly WAYLAND_SESSION="plasma.desktop"
readonly X11_SESSION="plasmax11.desktop"

# The drop-in steamos-manager owns and that SDDM actually reads. The lock
# rewrites this exact file rather than adding another one, so there is no
# reliance on how SDDM's conf.d sort order handles punctuation.
readonly DROPIN="/etc/sddm.conf.d/zz-steamos-autologin.conf"
readonly UNIT_NAME="force-desktop-boot.service"
readonly UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

# GPU selection is a systemd *user drop-in scoped to gamescope-session.service*.
#
# The obvious hook, ~/.config/environment.d/, is wrong: it applies to the whole
# user session, so forcing the dGPU there drags the KDE desktop onto the
# discrete card too and burns battery all day on a laptop. A drop-in reaches
# gamescope and nothing else (verified with `systemctl --user show`).
#
# It has to be an env var rather than gamescope's own --prefer-vk-device flag,
# because SteamOS's /usr/lib/steamos/gamescope-session takes no config file and
# the flag cannot be injected without patching a root-owned unit on the
# read-only rootfs.
readonly GPU_DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/gamescope-session.service.d"
readonly GPU_DROPIN="${GPU_DROPIN_DIR}/10-steamctl-gpu.conf"

# Superseded location, cleaned up on sight so an upgrade cannot leave the
# session-wide version silently in force alongside the scoped one.
readonly GPU_LEGACY_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/10-gamescope-gpu.conf"

# Screen selection. SteamOS hardcodes the display preference in the middle of
# /usr/lib/steamos/gamescope-session:
#
#     exec gamescope ... -O '*',eDP-1
#
# That file is root-owned on the read-only rootfs, and the flag has no env
# equivalent. But the script calls `gamescope` *unqualified*, so PATH decides
# which binary runs — a wrapper placed ahead of /usr/bin rewrites the flag
# without touching Valve's script, which means SteamOS updates cannot break it
# and we never have to duplicate a 260-line session script.
#
# The wrapper dir is deliberately not ~/.local/bin: it is put on the PATH of
# gamescope-session.service only, so typing `gamescope` in a terminal still
# gets the stock binary.
readonly SCREEN_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/steamctl/screen"
readonly WRAPPER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/steamctl/bin"
readonly WRAPPER="${WRAPPER_DIR}/gamescope"
readonly SCREEN_DROPIN="${GPU_DROPIN_DIR}/20-steamctl-screen.conf"

# Lid behaviour. Leaving Game Mode with the lid shut puts the laptop to sleep:
# gamescope segfaults during teardown, which tears down the DRM outputs, so for
# a moment logind sees no external display, stops treating the machine as
# docked, and falls back to HandleLidSwitch=suspend.
#
# HandleLidSwitchDocked is already `ignore`, but it cannot help — it depends on
# display detection, which is exactly what breaks. HandleLidSwitchExternalPower
# keys off AC power instead, so it holds through the glitch. On battery the lid
# still suspends, which is what you want in a bag.
readonly LID_DROPIN="/etc/systemd/logind.conf.d/10-steamctl-lid.conf"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

require_steamosctl() {
  command -v steamosctl >/dev/null 2>&1 \
    || die "steamosctl not found — this script only runs on SteamOS."
}

# steamosctl prints just the bare value for these getters.
current_mode() { steamosctl get-default-login-mode 2>/dev/null || echo "unknown"; }
current_session() { steamosctl get-default-desktop-session 2>/dev/null || echo "unknown"; }

# What SDDM will actually autologin into. It merges /etc/sddm.conf.d/*.conf in
# alphabetical order with last-one-wins, so the real answer is the final
# Session= line across the sorted set — that is why steamos-manager writes its
# override as zz-steamos-autologin.conf rather than editing steamos.conf.
effective_session() {
  local f line last=""
  # Bash expands a glob already sorted, so no `sort` is needed — and looping
  # over the glob directly keeps filenames containing spaces intact, which a
  # $(... | sort) command substitution would word-split and silently skip.
  for f in /etc/sddm.conf.d/*.conf; do
    [[ -r "$f" ]] || continue
    line="$(grep '^Session=' "$f" | tail -1)" || true
    [[ -n "$line" ]] && last="${line#Session=}"
  done
  printf '%s' "${last:-unknown}"
}

lock_installed() { systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; }

show_status() {
  local mode session effective
  mode="$(current_mode)"
  session="$(current_session)"
  effective="$(effective_session)"

  printf 'Boot mode : %s\n' "$mode"
  printf 'Session   : %s\n' "$session"
  printf 'SDDM will : autologin into %s\n' "$effective"

  if lock_installed; then
    printf 'Lock      : ENABLED (%s re-asserts desktop before every boot)\n' "$UNIT_NAME"
  else
    printf 'Lock      : off — Steam or a SteamOS update can change this back\n'
  fi

  show_gpu_status
  show_screen_status
  show_lid_status

  # The two can disagree if something hand-edited sddm.conf.d.
  if [[ "$mode" == "desktop" && "$effective" == "gamescope-wayland.desktop" ]]; then
    info "!! Mismatch: mode says desktop but SDDM is still set to gamescope."
  fi

  case "$mode" in
    desktop) info "-> Next boot goes to the KDE desktop." ;;
    game)    info "-> Next boot goes to the Steam Game Mode UI." ;;
    *)       info "-> Could not read the current mode." ;;
  esac
}

set_desktop() {
  local session="$1"

  # Guard against a typo silently setting a session SDDM cannot start. The
  # match is anchored to a whole list entry: a plain substring test would let
  # a name that merely appears inside another valid name pass.
  steamosctl get-valid-desktop-sessions 2>/dev/null \
    | sed -nE 's/^[[:space:]]*-[[:space:]]*//p' \
    | grep -qxF -- "$session" \
    || die "'$session' is not a valid desktop session on this system."

  info "Setting default desktop session to $session ..."
  steamosctl set-default-desktop-session "$session"

  info "Setting default login mode to desktop ..."
  steamosctl set-default-login-mode desktop

  [[ "$(current_mode)" == "desktop" ]] \
    || die "Setting did not stick — steamos-manager still reports '$(current_mode)'."

  printf '\nOK — this machine will now boot to Desktop Mode (%s).\n' "$session"
}

# Make it permanent. A oneshot ordered Before=sddm.service rewrites the
# autologin drop-in on every boot, so whatever Steam or a SteamOS update did to
# it in the meantime is irrelevant by the time SDDM reads it.
#
# This deliberately does NOT touch steamos-manager's own state, so Steam's
# "Return to Gaming Mode" still works as a temporary, this-session-only switch.
# You get Game Mode when you ask for it, and Desktop Mode on every boot.
install_lock() {
  local session="$1"

  info "Installing ${UNIT_NAME} (needs sudo) ..."
  sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Force SteamOS to autologin into Desktop Mode
# SDDM reads its config at startup, so this must land first.
Before=sddm.service
ConditionPathIsDirectory=/etc/sddm.conf.d

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'printf "[Autologin]\\\\nSession=${session}\\\\n" > ${DROPIN}'

[Install]
WantedBy=sddm.service
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT_NAME" >/dev/null

  lock_installed || die "Unit did not enable — check: systemctl status $UNIT_NAME"

  # Prove the unit produces the right file rather than trusting it blindly.
  info "Test-running the unit ..."
  sudo systemctl start "$UNIT_NAME"
  local produced
  produced="$(effective_session)"
  [[ "$produced" == "$session" ]] \
    || die "Unit ran but SDDM would still autologin into '$produced'."

  printf '\nLOCKED — every boot is forced to Desktop Mode (%s).\n' "$session"
  info "Remove the lock with: $0 unlock"
}

remove_lock() {
  if ! lock_installed && [[ ! -f "$UNIT_PATH" ]]; then
    info "No lock installed — nothing to do."
    return
  fi

  info "Removing ${UNIT_NAME} (needs sudo) ..."
  sudo systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  sudo rm -f "$UNIT_PATH"
  sudo systemctl daemon-reload

  printf '\nLock removed. Boot mode is now whatever steamosctl says (%s).\n' "$(current_mode)"
}

# Bare invocation. Reads live system state on every redraw rather than caching
# it, so the menu cannot go stale after an action changes something.
main_menu() {
  local choice lock_label lid_label

  while true; do
    if lock_installed; then
      lock_label="Turn desktop-boot OFF  (currently ON)"
    else
      lock_label="Turn desktop-boot ON   (currently off)"
    fi

    printf '\n=== SteamOS Laptop Manager ===\n\n'
    show_status
    if lid_awake_enabled; then
      lid_label="Let lid-close sleep the machine again (currently: stays awake on AC)"
    else
      lid_label="Stop lid-close sleeping the machine on AC (fixes black screen)"
    fi

    printf '\n  1) %s\n' "$lock_label"
    printf '  2) Pick GPU for games\n'
    printf '  3) Pick screen for Steam\n'
    printf '  4) %s\n' "$lid_label"
    printf '  5) Quit\n\n'

    # A bare `read` returning non-zero means EOF (piped or Ctrl-D), which must
    # exit rather than spin forever on an unreadable stdin.
    read -rp 'Choice [1-5]: ' choice || { printf '\n'; return 0; }

    case "$choice" in
      1) toggle ;;
      2) pick_gpu ;;
      3) pick_screen ;;
      4) if lid_awake_enabled; then clear_lid_awake; else set_lid_awake; fi ;;
      5|q|quit|exit) return 0 ;;
      "") ;;
      *) info "Not a valid choice: '$choice'" ;;
    esac
  done
}

# The lock being enabled is the single source of truth for
# "is this feature on", so the toggle reads that rather than tracking its own
# state file that could drift from reality.
toggle() {
  if lock_installed; then
    printf 'Desktop boot is ON — turning it OFF.\n\n'
    remove_lock
    set_game
  else
    printf 'Desktop boot is OFF — turning it ON.\n\n'
    set_desktop "$WAYLAND_SESSION"
    install_lock "$WAYLAND_SESSION"
  fi
}

# ----------------------------------------------------------------- Diagnostics

readonly DIAG_MARK="${XDG_CONFIG_HOME:-$HOME/.config}/steamctl/mark"

# Drop a timestamp so `diag` can report only what happened after it. Without a
# baseline, the suspend that prompted this whole investigation still shows in
# the log and it is impossible to tell old evidence from new.
mark_diag() {
  mkdir -p "$(dirname "$DIAG_MARK")"
  date '+%Y-%m-%d %H:%M:%S' > "$DIAG_MARK"
  printf 'Marked %s — now switch to Game Mode and come back.\n' "$(cat "$DIAG_MARK")"
  info "Then run: $0 diag"
}

run_diag() {
  local since
  if [[ -r "$DIAG_MARK" ]]; then
    since="$(cat "$DIAG_MARK")"
    printf 'Events since mark (%s)\n\n' "$since"
  else
    since="$(date '+%Y-%m-%d') 00:00:00"
    info "No mark set — showing everything today. Use '$0 diag mark' first."
    printf '\n'
  fi

  local suspends crashes
  suspends="$(journalctl --since "$since" --no-pager 2>/dev/null \
                | grep -cE 'PM: suspend entry' || true)"
  crashes="$(journalctl --since "$since" --no-pager 2>/dev/null \
                | grep -cE 'gamescope.*(SEGV|segfault)' || true)"

  if (( suspends > 0 )); then
    printf 'SUSPENDS  : %s  <-- the lid fix did NOT hold\n' "$suspends"
    journalctl --since "$since" --no-pager 2>/dev/null \
      | grep -E 'Suspending\.\.\.|PM: suspend entry|Lid (opened|closed)' | head -6 | sed 's/^/            /'
  else
    printf 'SUSPENDS  : 0  <-- good, the machine stayed awake\n'
  fi

  printf 'gamescope crashes: %s (upstream bug; expected even when the fix works)\n' "$crashes"

  printf '\n'
  show_lid_status
  printf '\nDisplays now:\n'
  local c n s e
  for c in /sys/class/drm/card*-*/; do
    [[ -r "${c}status" ]] || continue
    s="$(cat "${c}status")"
    [[ "$s" == "connected" ]] || continue
    n="$(basename "$c")"; e="$(cat "${c}enabled" 2>/dev/null)"
    printf '  %-12s %s\n' "${n#card*-}" "$e"
  done
}

# --------------------------------------------------------------- Lid handling

lid_awake_enabled() { [[ -e "$LID_DROPIN" ]]; }

# Ask logind what it will actually do, rather than trusting that our file is
# the last word — another drop-in could override it.
effective_lid_action() {
  local v
  v="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandleLidSwitchExternalPower 2>/dev/null \
        | sed -E 's/^s "?//; s/"?$//')"
  # An empty value means "inherit HandleLidSwitch".
  if [[ -z "$v" ]]; then
    v="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null \
          | sed -E 's/^s "?//; s/"?$//')"
    v="${v:-unknown} (inherited)"
  fi
  printf '%s' "$v"
}

show_lid_status() {
  local act
  act="$(effective_lid_action)"

  if lid_awake_enabled; then
    printf 'Lid on AC : %s — stays awake when you leave Game Mode\n' "$act"
  else
    printf 'Lid on AC : %s — closing the lid can sleep the machine\n' "$act"
  fi
}

set_lid_awake() {
  info "Writing ${LID_DROPIN} (needs sudo) ..."
  sudo mkdir -p "$(dirname "$LID_DROPIN")"
  sudo tee "$LID_DROPIN" >/dev/null <<'EOF'
# Written by steamctl.sh.
# Leaving Game Mode with the lid shut used to suspend the laptop: gamescope
# crashes on teardown, logind briefly sees no external display, stops treating
# the machine as docked, and applies HandleLidSwitch=suspend.
# Keying off AC power instead survives that momentary loss of the display.
# On battery the lid still suspends.
[Login]
HandleLidSwitchExternalPower=ignore
EOF

  # Reload rather than restart: restarting logind can tear down live sessions.
  sudo systemctl reload systemd-logind

  local act
  act="$(effective_lid_action)"
  [[ "$act" == "ignore" ]] \
    || die "logind still reports '$act' for lid-on-AC — setting did not apply."

  printf '\nOK — on AC power, closing the lid no longer sleeps the machine.\n'
  info "On battery it still suspends. Revert with: $0 lid suspend"
}

clear_lid_awake() {
  if ! lid_awake_enabled; then
    info "Lid handling is already stock — nothing to do."
    return
  fi

  info "Removing ${LID_DROPIN} (needs sudo) ..."
  sudo rm -f "$LID_DROPIN"
  sudo systemctl reload systemd-logind

  printf '\nLid handling restored to the SteamOS default (%s).\n' "$(effective_lid_action)"
}

# ------------------------------------------------------------- Screen picking

# Connected DRM connectors, by the exact names gamescope's -O flag expects
# (eDP-1, HDMI-A-2, ...). Read from sysfs rather than kscreen-doctor so this
# works from a TTY and from inside Game Mode, where no KDE session exists.
list_screens() {
  local c n
  for c in /sys/class/drm/card*-*/; do
    [[ -r "${c}status" ]] || continue
    [[ "$(cat "${c}status")" == "connected" ]] || continue
    n="$(basename "$c")"
    printf '%s\n' "${n#card*-}"
  done
}

current_screen() {
  [[ -r "$SCREEN_CONF" ]] || return 0
  head -1 "$SCREEN_CONF" | tr -d '[:space:]'
}

show_screen_status() {
  local pinned
  pinned="$(current_screen)"

  if [[ -n "$pinned" ]]; then
    printf 'Steam screen: %s\n' "$pinned"
  else
    printf 'Steam screen: auto — SteamOS default (any output, then eDP-1)\n'
  fi
}

# The wrapper reads the chosen screen at *run* time, so changing screens later
# only rewrites a one-line config file — the wrapper itself never changes.
install_screen_wrapper() {
  mkdir -p "$WRAPPER_DIR" "$GPU_DROPIN_DIR"

  cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Installed by steamctl.sh. Forces gamescope onto a chosen display by
# rewriting -O/--prefer-output, then hands off to the real binary.
set -euo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/steamctl/screen"
real="${STEAMCTL_GAMESCOPE_BIN:-/usr/bin/gamescope}"

want=""
[[ -r "$conf" ]] && want="$(head -1 "$conf" | tr -d '[:space:]')"

# No preference recorded: behave exactly like stock gamescope.
[[ -n "$want" ]] || exec "$real" "$@"

# ",*" keeps a wildcard fallback after the chosen connector, so unplugging that
# display leaves Game Mode still able to start rather than showing nothing.
pref="${want},*"

args=(); skip=0; replaced=0
for a in "$@"; do
  if (( skip )); then skip=0; continue; fi
  case "$a" in
    -O|--prefer-output)   args+=("$a" "$pref"); skip=1; replaced=1 ;;
    --prefer-output=*)    args+=("--prefer-output=$pref"); replaced=1 ;;
    *)                    args+=("$a") ;;
  esac
done
(( replaced )) || args+=(-O "$pref")

exec "$real" "${args[@]}"
WRAPPER_EOF

  chmod +x "$WRAPPER"

  # systemd units do not inherit the login PATH, so it must be stated in full.
  # Built from the live user-manager PATH so we extend it rather than replace
  # it with a guess.
  local base
  base="$(systemctl --user show-environment | sed -n 's/^PATH=//p')"
  base="${base:-/usr/local/sbin:/usr/local/bin:/usr/bin}"

  {
    printf '# Written by steamctl.sh — puts the gamescope wrapper ahead of /usr/bin.\n'
    printf '[Service]\n'
    printf 'Environment=PATH=%s:%s\n' "$WRAPPER_DIR" "$base"
  } > "$SCREEN_DROPIN"

  systemctl --user daemon-reload
}

remove_screen_wrapper() {
  rm -f "$WRAPPER" "$SCREEN_DROPIN" "$SCREEN_CONF"
  rmdir "$WRAPPER_DIR" 2>/dev/null || true
  rmdir "$(dirname "$SCREEN_CONF")" 2>/dev/null || true
  rmdir "$GPU_DROPIN_DIR" 2>/dev/null || true
  systemctl --user daemon-reload
}

pick_screen() {
  local -a screens=()
  local s pinned

  while read -r s; do screens+=("$s"); done < <(list_screens)
  (( ${#screens[@]} > 0 )) || die "No connected displays found."

  pinned="$(current_screen)"

  printf 'Which screen should Steam (Game Mode) use?\n\n'
  local i marker
  for i in "${!screens[@]}"; do
    marker="  "
    [[ "${screens[$i]}" == "$pinned" ]] && marker="* "
    printf '%s%d) %s\n' "$marker" "$((i + 1))" "${screens[$i]}"
  done
  printf '  %d) auto — leave SteamOS to choose\n\n' "$(( ${#screens[@]} + 1 ))"
  [[ -n "$pinned" ]] && printf '(* = current choice)\n\n'

  local choice
  read -rp "Choice [1-$(( ${#screens[@]} + 1 ))]: " choice || { printf '\n'; return 0; }

  [[ "$choice" =~ ^[0-9]+$ ]] || die "Not a number: '$choice'"

  if (( choice == ${#screens[@]} + 1 )); then
    reset_screen
    return
  fi

  (( choice >= 1 && choice <= ${#screens[@]} )) || die "Choice out of range: $choice"

  local want="${screens[$(( choice - 1 ))]}"
  mkdir -p "$(dirname "$SCREEN_CONF")"
  printf '%s\n' "$want" > "$SCREEN_CONF"
  install_screen_wrapper

  printf '\nOK — Steam will open on: %s\n' "$want"
  info "Takes effect next time you enter Game Mode."
}

reset_screen() {
  if [[ -e "$SCREEN_CONF" || -e "$WRAPPER" ]]; then
    remove_screen_wrapper
    printf '\nScreen choice cleared — back to the SteamOS default.\n'
  else
    info "No screen pinned — nothing to do."
  fi
}

# ---------------------------------------------------------------- GPU picking

# Enumerate Vulkan devices via the Mesa device-select layer. This is preferred
# over parsing lspci because it reports exactly the vendor:device IDs that
# MESA_VK_DEVICE_SELECT accepts, and it sees the proprietary NVIDIA driver too.
# Output lines look like:
#   GPU 0: 10de:25ac "NVIDIA GeForce RTX 3050 6GB Laptop GPU" discrete GPU 0000:01:00.0
list_gpus() {
  MESA_VK_DEVICE_SELECT=list vulkaninfo --summary 2>&1 \
    | sed -nE 's/^[[:space:]]*GPU [0-9]+: ([0-9a-fA-F]{4}:[0-9a-fA-F]{4}) "(.*)" (discrete|integrated|virtual|cpu) GPU.*/\1\t\2\t\3/p'
}

# The vendor:device currently pinned, or empty when running stock.
current_gpu_id() {
  [[ -r "$GPU_DROPIN" ]] || return 0
  sed -nE 's/^Environment=MESA_VK_DEVICE_SELECT=(.*)$/\1/p' "$GPU_DROPIN" | tail -1
}

gpu_name_for_id() {
  local want="$1" id name
  while IFS=$'\t' read -r id name _; do
    [[ "$id" == "$want" ]] && { printf '%s' "$name"; return; }
  done < <(list_gpus)
  printf 'unknown device (%s)' "$want"
}

show_gpu_status() {
  local pinned
  pinned="$(current_gpu_id)"

  if [[ -n "$pinned" ]]; then
    printf 'Game GPU  : %s (gamescope only)\n' "$(gpu_name_for_id "$pinned")"
    printf 'Pinned by : %s\n' "$GPU_DROPIN"
  else
    printf 'Game GPU  : not pinned — gamescope picks its own default\n'
  fi

  if [[ -e "$GPU_LEGACY_ENV_FILE" ]]; then
    info "!! Stale session-wide file found: $GPU_LEGACY_ENV_FILE"
    info "   Run '$0 gpu reset' to clear it — it affects the desktop, not just games."
  fi
}

write_gpu_env() {
  local id="$1" name="$2" vendor="${1%%:*}"

  mkdir -p "$GPU_DROPIN_DIR"

  {
    printf '# Written by steamctl.sh — pins the GPU gamescope and games use.\n'
    printf '# Device: %s\n' "$name"
    printf '# Scoped to gamescope-session.service so the desktop is unaffected.\n'
    printf '# Remove (or run: steamctl.sh gpu reset) to go back to stock.\n'
    printf '[Service]\n'
    printf 'Environment=MESA_VK_DEVICE_SELECT=%s\n' "$id"

    # The NVIDIA-specific vars only matter for the NVIDIA card. They make GL
    # titles (older/native games, not DXVK) render on the dGPU instead of
    # silently falling back to the iGPU. Setting them when AMD is selected
    # would force offload the wrong way, so they are vendor-gated.
    if [[ "$vendor" == "10de" ]]; then
      printf 'Environment=__NV_PRIME_RENDER_OFFLOAD=1\n'
      printf 'Environment=__GLX_VENDOR_LIBRARY_NAME=nvidia\n'
      printf 'Environment=__VK_LAYER_NV_optimus=NVIDIA_only\n'
    fi
  } > "$GPU_DROPIN"

  # A drop-in only exists as far as systemd is concerned after a reload.
  systemctl --user daemon-reload

  clear_legacy_gpu_env
}

# The pre-drop-in versions of this script wrote a session-wide environment.d
# file. Left in place it would keep forcing the desktop onto the dGPU even
# after a "reset", so it is removed wherever it is found.
clear_legacy_gpu_env() {
  [[ -e "$GPU_LEGACY_ENV_FILE" ]] || return 0
  rm -f "$GPU_LEGACY_ENV_FILE"
  info "Removed superseded session-wide file: $GPU_LEGACY_ENV_FILE"
}

# Prove the choice actually takes effect, rather than trusting that writing the
# file was enough.
verify_gpu_choice() {
  local id="$1" got
  got="$(MESA_VK_DEVICE_SELECT="$id" vulkaninfo --summary 2>/dev/null \
          | sed -nE 's/^[[:space:]]*deviceName[[:space:]]+= (.*)$/\1/p' | head -1)"
  [[ -n "$got" ]] || { info "!! Could not verify — vulkaninfo returned nothing."; return; }
  info "Verified: Vulkan now reports '$got' as the primary device."
}

pick_gpu() {
  local -a ids=() names=() kinds=()
  local id name kind pinned

  while IFS=$'\t' read -r id name kind; do
    ids+=("$id"); names+=("$name"); kinds+=("$kind")
  done < <(list_gpus)

  (( ${#ids[@]} > 0 )) || die "No Vulkan devices found — is vulkaninfo working?"

  pinned="$(current_gpu_id)"

  printf 'Which GPU should gamescope use for games?\n\n'
  local i marker
  for i in "${!ids[@]}"; do
    marker="  "
    [[ "${ids[$i]}" == "$pinned" ]] && marker="* "
    printf '%s%d) %s  [%s, %s]\n' "$marker" "$((i + 1))" "${names[$i]}" "${kinds[$i]}" "${ids[$i]}"
  done
  printf '  %d) stock — do not pin anything\n\n' "$(( ${#ids[@]} + 1 ))"
  [[ -n "$pinned" ]] && printf '(* = current choice)\n\n'

  # Same EOF guard as the menu: without it, `set -e` would abort the whole
  # script on a closed stdin instead of returning to the caller.
  local choice
  read -rp "Choice [1-$(( ${#ids[@]} + 1 ))]: " choice || { printf '\n'; return 0; }

  [[ "$choice" =~ ^[0-9]+$ ]] || die "Not a number: '$choice'"

  if (( choice == ${#ids[@]} + 1 )); then
    reset_gpu
    return
  fi

  (( choice >= 1 && choice <= ${#ids[@]} )) || die "Choice out of range: $choice"

  local idx=$(( choice - 1 ))
  info "Pinning ${names[$idx]} ..."
  write_gpu_env "${ids[$idx]}" "${names[$idx]}"
  verify_gpu_choice "${ids[$idx]}"

  printf '\nOK — games will run on: %s\n' "${names[$idx]}"
  info "Takes effect next time Game Mode starts (the drop-in is read when gamescope-session launches)."
}

reset_gpu() {
  local had=0
  [[ -e "$GPU_DROPIN" ]] && had=1
  [[ -e "$GPU_LEGACY_ENV_FILE" ]] && had=1

  if (( had )); then
    rm -f "$GPU_DROPIN"
    rmdir "$GPU_DROPIN_DIR" 2>/dev/null || true
    clear_legacy_gpu_env
    systemctl --user daemon-reload
    printf '\nGPU pin removed — back to stock behaviour.\n'
    info "Takes effect next time Game Mode starts."
  else
    info "No GPU pin set — nothing to do."
  fi
}

set_game() {
  info "Setting default login mode to game ..."
  steamosctl set-default-login-mode game

  [[ "$(current_mode)" == "game" ]] \
    || die "Setting did not stick — steamos-manager still reports '$(current_mode)'."

  printf '\nOK — this machine will now boot to Game Mode.\n'
}

main() {
  # --help before the SteamOS check: reading the usage on a machine that cannot
  # run the script is the normal way to find out what it does.
  case "${1:-menu}" in
    -h|--help|help)
      # Print the header block: line 2 through the first blank line. Using a
      # range that ends at the blank line means editing the header cannot
      # silently truncate --help the way a hardcoded line count would.
      sed -n '2,/^$/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
      return 0
      ;;
  esac

  require_steamosctl

  case "${1:-menu}" in
    menu)
      main_menu
      ;;
    toggle)
      toggle
      ;;
    status)
      show_status
      ;;
    desktop)
      case "${2:-wayland}" in
        wayland) set_desktop "$WAYLAND_SESSION" ;;
        x11)     set_desktop "$X11_SESSION" ;;
        *)       die "Unknown session '$2' — use 'wayland' or 'x11'." ;;
      esac
      info "Revert with: $0 game    Make permanent with: $0 lock"
      ;;
    lock)
      case "${2:-wayland}" in
        wayland) set_desktop "$WAYLAND_SESSION"; install_lock "$WAYLAND_SESSION" ;;
        x11)     set_desktop "$X11_SESSION";     install_lock "$X11_SESSION" ;;
        *)       die "Unknown session '$2' — use 'wayland' or 'x11'." ;;
      esac
      ;;
    unlock)
      remove_lock
      ;;
    gpu)
      case "${2:-pick}" in
        pick)   pick_gpu ;;
        status) show_gpu_status ;;
        reset)  reset_gpu ;;
        *)      die "Unknown gpu command '$2' — use: pick, status, reset" ;;
      esac
      ;;
    diag)
      case "${2:-report}" in
        mark)   mark_diag ;;
        report) run_diag ;;
        *)      die "Unknown diag command '$2' — use: mark, report" ;;
      esac
      ;;
    lid)
      case "${2:-status}" in
        status)  show_lid_status ;;
        awake)   set_lid_awake ;;
        suspend) clear_lid_awake ;;
        *)       die "Unknown lid command '$2' — use: status, awake, suspend" ;;
      esac
      ;;
    screen)
      case "${2:-pick}" in
        pick)   pick_screen ;;
        status) show_screen_status ;;
        reset)  reset_screen ;;
        *)      die "Unknown screen command '$2' — use: pick, status, reset" ;;
      esac
      ;;
    game)
      # Reverting to Game Mode while the lock is active would be undone on the
      # next boot, which looks like the script silently failing.
      if lock_installed; then
        die "The desktop lock is enabled — run '$0 unlock' first."
      fi
      set_game
      ;;
    *)
      die "Unknown command '$1' — try: status, desktop, game, help"
      ;;
  esac
}

main "$@"
