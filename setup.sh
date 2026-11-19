#!/bin/zsh
# setup.sh
# One-shot setup for isolated Claude Desktop + Claude Code profiles on macOS.
#
# Start with a normal Claude.app in /Applications, extract this folder, then run:
#   chmod +x setup.sh
#   ./setup.sh                          (both profiles start fresh)
#   ./setup.sh --migrate-to work        (existing login goes to Work)
#   ./setup.sh --migrate-to personal    (existing login goes to Personal)
#
# Logos: keep them next to this script, named claude-icon-<profile>.png
#   claude-icon-work.png
#   claude-icon-personal.png
# Missing logos are fine; that profile keeps the standard Claude icon.
# PNG logos are shrunk onto Apple's icon grid automatically so they match the
# size of other Dock icons (use --no-icon-pad if yours already has padding).
#
# What it does:
#   1. Moves /Applications/Claude.app to ~/Applications/.claude-clones/Claude.app
#      (hidden from Spotlight and Launchpad)
#   2. Only with --migrate-to: copies your existing Claude login/chats and ~/.claude
#      into that profile (copy, not move; originals stay put; skipped if the
#      profile already has data)
#   3. For each profile: creates ~/.claude-<name>/{desktop,code}, clones the app,
#      applies the logo, builds a Spotlight launcher "Claude <Name>"
#   4. Puts a "Claude <Name>" shortcut on the Desktop for each profile
#      (skip with --no-desktop)
#   5. Turns off Claude's built-in updater (it relaunches without the profile
#      and opens the wrong account) and installs a watchdog that relaunches any
#      profile app started without its profile. The launchers install updates.
#   6. Adds aliases to ~/.zshrc for each profile:
#        claude-<name>       Claude Code (CLI) in that profile
#        claude-<name>-app   Opens or focuses that profile's Desktop app
#
# Updating Claude: automatic. Each launch downloads the latest release if needed
# and rebuilds that profile's copy with its logo.
# Custom profile list: ./setup.sh work personal clientx

set -euo pipefail

MIGRATE_TO=""             # no migration unless --migrate-to is given
DESKTOP_SHORTCUTS=1       # Desktop shortcuts unless --no-desktop is given
ICON_PAD=1                # shrink PNG logos onto Apple's icon grid unless --no-icon-pad
ICON_ART=824              # artwork size on the 1024px canvas (Apple's grid is 824)
UPDATER_POLICY=1          # turn off Claude's built-in updater unless --keep-auto-update is given
PROFILES=()

usage() {
  echo "Usage: ./setup.sh [--migrate-to <profile>] [--no-desktop] [--no-icon-pad] [--keep-auto-update] [profile ...]"
  echo "  --migrate-to <profile>  Copy your existing Claude login and ~/.claude into this profile"
  echo "                          (default: no migration, every profile starts fresh)"
  echo "  --no-desktop            Do not put shortcuts on the Desktop"
  echo "  --no-icon-pad           Use PNG logos as-is (if they already include padding)"
  echo "  --keep-auto-update      Leave Claude's built-in updater on (it relaunches without the profile)"
  echo "  profile ...             Profiles to create (default: work personal)"
  exit 1
}

while (( $# )); do
  case "$1" in
    --migrate-to)   [[ -n "${2:-}" ]] || usage; MIGRATE_TO="$2"; shift 2 ;;
    --migrate-to=*) MIGRATE_TO="${1#*=}"; shift ;;
    --no-desktop)   DESKTOP_SHORTCUTS=0; shift ;;
    --no-icon-pad)  ICON_PAD=0; shift ;;
    --keep-auto-update) UPDATER_POLICY=0; shift ;;
    -h|--help)      usage ;;
    -*)             echo "Unknown option: $1"; usage ;;
    *)              PROFILES+=("$1"); shift ;;
  esac
done
(( ${#PROFILES} )) || PROFILES=(work personal)

if [[ -n "$MIGRATE_TO" && ${PROFILES[(Ie)$MIGRATE_TO]} -eq 0 ]]; then
  echo "--migrate-to '$MIGRATE_TO' is not one of the profiles being created: ${PROFILES[*]}"
  exit 1
fi

SCRIPT_DIR="${0:A:h}"
CLONE_DIR="$HOME/Applications/.claude-clones"
SOURCE="$CLONE_DIR/Claude.app"
ORIG="/Applications/Claude.app"

# Gracefully quit a process by PID and wait for it to exit
quit_pid() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || return 0
  for i in {1..40}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  echo "    Process $pid did not quit; please close it and rerun."
  exit 1
}

mkdir -p "$CLONE_DIR"

# ---------- 1. Hide the original ----------
if [[ -d "$ORIG" ]]; then
  PID=$(pgrep -f "^$ORIG/Contents/MacOS/Claude" | head -1 || true)
  if [[ -n "$PID" ]]; then
    echo "==> Quitting the original Claude app"
    quit_pid "$PID"
  fi
  echo "==> Hiding original Claude.app in $CLONE_DIR"
  rm -rf "$SOURCE"
  mv "$ORIG" "$SOURCE"
fi
[[ -d "$SOURCE" ]] || { echo "Claude.app not found. Install it to /Applications and rerun."; exit 1; }
# Clear any stale custom-icon flag (shows as a folder icon in every copy made
# from it) and keep claude:// links from opening this profile-less copy
xattr -d com.apple.FinderInfo "$SOURCE" 2>/dev/null || true
rm -f "$SOURCE/Icon"$'\r' 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$SOURCE" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt" 2>/dev/null || true

# ---------- 2. First-run migration of the existing login ----------
if [[ -n "$MIGRATE_TO" ]]; then
  M="$HOME/.claude-$MIGRATE_TO"
  OLD_DATA="$HOME/Library/Application Support/Claude"
  if [[ -d "$OLD_DATA" && ! -e "$M/desktop" ]]; then
    echo "==> Copying existing Claude Desktop data into $M/desktop"
    mkdir -p "$M"
    ditto "$OLD_DATA" "$M/desktop"
  fi
  if [[ -d "$HOME/.claude" && ! -e "$M/code" ]]; then
    echo "==> Copying existing ~/.claude into $M/code"
    mkdir -p "$M"
    ditto "$HOME/.claude" "$M/code"
  fi
fi

# ---------- 3. Build each profile ----------
for NAME in $PROFILES; do
  TITLE="${(C)NAME}"
  PROFILE="$HOME/.claude-$NAME"
  DATA="$PROFILE/desktop"
  CODE="$PROFILE/code"
  CLONE="$CLONE_DIR/Claude $TITLE.app"
  LAUNCHER="$HOME/Applications/Claude $TITLE.app"

  echo ""
  echo "######## Profile: $TITLE ########"
  mkdir -p "$DATA" "$CODE"

  # Copy the logo from the zip folder into the profile so reruns keep it
  for ext in png icns; do
    if [[ -f "$SCRIPT_DIR/claude-icon-$NAME.$ext" ]]; then
      rm -f "$PROFILE"/icon.png "$PROFILE"/icon.icns
      cp "$SCRIPT_DIR/claude-icon-$NAME.$ext" "$PROFILE/icon.$ext"
      break
    fi
  done

  # Quit this profile if it is running, so the clone can be rebuilt
  PID=$(pgrep -f "Contents/MacOS/Claude --user-data-dir=$DATA" | head -1 || true)
  if [[ -n "$PID" ]]; then
    echo "==> Quitting running $TITLE instance"
    quit_pid "$PID"
  fi

  echo "==> Cloning Claude.app"
  if [[ -e "$CLONE" ]]; then
    mkdir -p "$CLONE_DIR/.trash"
    mv "$CLONE" "$CLONE_DIR/.trash/${CLONE:t}.$$"
  fi
  ditto "$SOURCE" "$CLONE"

  ICON=""
  for f in "$PROFILE/icon.icns" "$PROFILE/icon.png"; do
    [[ -f "$f" ]] && { ICON="$f"; break; }
  done

  ICNS=""
  if [[ -n "$ICON" ]]; then
    echo "==> Applying logo $ICON"
    if [[ "$ICON" == *.png ]]; then
      # macOS icons sit inside transparent padding (824px artwork on a 1024px
      # canvas). Full-bleed logos look oversized in the Dock, so pad them.
      if (( ICON_PAD )); then
        PADDED="$PROFILE/.icon-padded.png"
        OFFSET=$(( (1024 - ICON_ART) / 2 ))
        osascript > /dev/null <<EOF
use framework "AppKit"
use scripting additions
set src to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICON"
set rep to current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSDeviceRGBColorSpace) bytesPerRow:0 bitsPerPixel:0
rep's setSize:{1024, 1024}
current application's NSGraphicsContext's saveGraphicsState()
current application's NSGraphicsContext's setCurrentContext:(current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:rep)
src's drawInRect:{{$OFFSET, $OFFSET}, {$ICON_ART, $ICON_ART}} fromRect:(current application's NSZeroRect) operation:(current application's NSCompositingOperationSourceOver) fraction:1.0
current application's NSGraphicsContext's restoreGraphicsState()
set pngData to rep's representationUsingType:(current application's NSBitmapImageFileTypePNG) |properties|:(current application's NSDictionary's dictionary())
pngData's writeToFile:"$PADDED" atomically:true
EOF
        [[ -f "$PADDED" ]] || { echo "    Could not pad logo; using it as-is"; PADDED="$ICON"; }
        ICON="$PADDED"
      fi

      # Build a proper .icns via an iconset (sips cannot reliably write .icns)
      ICNS="$PROFILE/.icon-converted.icns"
      ISET="$(mktemp -d)/icon.iconset"
      mkdir -p "$ISET"
      for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$ICON" --out "$ISET/icon_${sz}x${sz}.png" > /dev/null
        sips -z $((sz*2)) $((sz*2)) "$ICON" --out "$ISET/icon_${sz}x${sz}@2x.png" > /dev/null
      done
      rm -f "$ICNS"
      iconutil -c icns "$ISET" -o "$ICNS"
      rm -rf "${ISET:h}"
    else
      ICNS="$ICON"
    fi
    osascript > /dev/null <<EOF
use framework "AppKit"
set img to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICON"
current application's NSWorkspace's sharedWorkspace()'s setIcon:img forFile:"$CLONE" options:0
EOF
    rm -f "$PROFILE/.icon-version"
  else
    echo "==> No logo for $NAME, keeping the standard icon"
  fi

  echo "==> Writing launch script"
  cat > "$PROFILE/launch.sh" <<EOF
#!/bin/zsh
TITLE="$TITLE"
DATA="$DATA"
CODE="$CODE"
APP="$CLONE"
SOURCE="$SOURCE"
CLONE_DIR="$CLONE_DIR"
ICON="$ICON"
LOG="$PROFILE/launch.log"
EOF
  cat >> "$PROFILE/launch.sh" <<'EOF'

# Every launch:
#   1. Updates the shared base copy (Claude.app) to the latest release.
#   2. Rebuilds this profile's copy from it when the version differs or the
#      logo is missing. macOS refuses to change the icon of an app that has
#      already been launched, but a fresh copy accepts it, so rebuild instead
#      of patching.
#   3. Quits any copy of this profile running without its --user-data-dir
#      (that one shows the default, unseparated account).
#   4. Focuses the running window, or launches it with the profile flags and
#      checks that it came up with them.

autoload -Uz is-at-least
FEED="https://claude.ai/api/desktop/darwin/universal/zip/latest/redirect"
TEAM="Q6L2SF6YDW"   # Anthropic's code-signing team; downloads must match it
EXE="$APP/Contents/MacOS/Claude"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SHIPIT="$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt"
POLICY="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
ICON_FAILED="${LOG:h}/.icon-failed"   # version whose fresh copy still refused the logo

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Claude $TITLE\"" 2>/dev/null; }
version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null; }

# Main process of this profile (helpers run a different binary, so they do not match)
main_pid() { pgrep -f "Contents/MacOS/Claude --user-data-dir=$DATA" | head -1; }

# This profile's app started without --user-data-dir (e.g. by Claude's own updater)
stray_pids() {
  ps -axww -o pid=,args= | while read -r pid args; do
    [[ "$args" == "$EXE" || ( "$args" == "$EXE "* && "$args" != *--user-data-dir=* ) ]] && print -r -- "$pid"
  done
}

quit_pid() {
  kill -TERM "$1" 2>/dev/null || return 0
  for i in {1..40}; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$1" 2>/dev/null
  sleep 1
}

# macOS may refuse to delete files inside an app that has been launched, so
# move old copies aside (renaming is always allowed) and clear them when it can.
discard() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$CLONE_DIR/.trash"
  mv "$1" "$CLONE_DIR/.trash/${1:t}.$$.$RANDOM" 2>/dev/null || rm -rf "$1"
}

set_icon() {
  # setIcon returns false instead of throwing when macOS blocks the write
  osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) {
      const img = $.NSImage.alloc.initWithContentsOfFile(a[0])
      if (!img || img.isNil() || !$.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, a[1], 0)) throw new Error("setIcon was refused")
    }' "$ICON" "$1" >> "$LOG" 2>&1
}

update_source() {
  local url latest current tmp UA
  # claude.ai rejects requests without a user agent
  UA="Claude/$(version_of "$SOURCE") (Macintosh)"
  url=$(curl -sS -m 10 -A "$UA" -o /dev/null -w '%{redirect_url}' "$FEED" 2>> "$LOG")
  latest=${${url:h}:t}   # .../darwin/universal/<version>/Claude-<hash>.zip
  if [[ "$latest" != <->.<->.<-> ]]; then
    log "Update check failed (offline?); staying on $(version_of "$SOURCE")"
    return
  fi
  current=$(version_of "$SOURCE")
  [[ -n "$current" ]] && is-at-least "$latest" "$current" && return

  notify "Updating to Claude $latest..."
  log "Downloading Claude $latest (have ${current:-none})"
  tmp="$CLONE_DIR/.download"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if curl -sSfL -m 900 -A "$UA" -o "$tmp/Claude.zip" "$url" 2>> "$LOG" \
     && ditto -x -k "$tmp/Claude.zip" "$tmp" 2>> "$LOG" \
     && codesign --verify --deep --strict "$tmp/Claude.app" 2>> "$LOG" \
     && [[ "$(codesign -dv "$tmp/Claude.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] \
     && [[ "$(version_of "$tmp/Claude.app")" == "$latest" ]]; then
    discard "$SOURCE"
    mv "$tmp/Claude.app" "$SOURCE"
    log "Base copy updated to Claude $latest"
  else
    log "Download or signature check of Claude $latest failed; staying on ${current:-none}"
    notify "Update to $latest failed; see $LOG"
  fi
  rm -rf "$tmp"
}

needs_rebuild() {
  [[ -d "$APP" ]] || return 0
  [[ "$(version_of "$APP")" != "$(version_of "$SOURCE")" ]] && return 0
  # Don't rebuild (and prompt to restart) on every launch if this version's
  # fresh copy already refused the logo once
  [[ -n "$ICON" && -f "$ICON" && ! -e "$APP/Icon"$'\r' \
     && "$(cat "$ICON_FAILED" 2>/dev/null)" != "$(version_of "$SOURCE")" ]] && return 0
  return 1
}

rebuild() {
  local stage="$CLONE_DIR/.staging"
  rm -rf "$stage"; mkdir -p "$stage"
  ditto "$SOURCE" "$stage/${APP:t}" 2>> "$LOG" || { log "Could not copy $SOURCE"; rm -rf "$stage"; return 1; }
  # A "has custom icon" flag without its Icon\r file shows a plain folder icon,
  # so start clean; if the logo is refused, the copy keeps the standard icon
  xattr -d com.apple.FinderInfo "$stage/${APP:t}" 2>/dev/null
  rm -f "$ICON_FAILED"
  if [[ -n "$ICON" && -f "$ICON" ]] && ! set_icon "$stage/${APP:t}"; then
    log "Could not apply logo to the new copy"
    version_of "$SOURCE" > "$ICON_FAILED"
  fi
  discard "$APP"
  mv "$stage/${APP:t}" "$APP"
  rm -rf "$stage"
  "$LSREGISTER" -f "$APP" 2>/dev/null
  touch "$APP"
  log "Rebuilt $APP from Claude $(version_of "$APP")"
}

# One launcher at a time (both profiles share the base copy)
LOCK="$CLONE_DIR/.lock"
until mkdir "$LOCK" 2>/dev/null; do
  [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]] && rmdir "$LOCK" 2>/dev/null
  sleep 1
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
rm -rf "$CLONE_DIR/.trash" 2>/dev/null

for pid in $(stray_pids); do
  log "Quitting Claude $TITLE started without its profile (pid $pid)"
  quit_pid "$pid"
done

# The hidden base copy has no profile, so it always opens the default account
for pid in $(pgrep -f "^$SOURCE/Contents/MacOS/Claude"); do
  log "Quitting the base Claude.app (pid $pid); it opens the default account"
  quit_pid "$pid"
done

# An update staged by Claude's own updater installs on quit and relaunches
# without the profile. Throw it away; this script installs updates instead.
if [[ -d "$SHIPIT" ]]; then
  rm -rf "$SHIPIT" 2>/dev/null && log "Removed an update staged by Claude's built-in updater"
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :disableAutoUpdates' "$POLICY" 2>/dev/null)" != "true" ]]; then
  log "Claude's built-in updater is on ($POLICY missing); rerun setup.sh to turn it off"
fi

# If Claude's own updater got to this copy first, keep its newer version
if [[ -d "$APP" ]] && ! is-at-least "$(version_of "$APP")" "$(version_of "$SOURCE")"; then
  log "Adopting newer Claude $(version_of "$APP") from $APP as the base copy"
  rm -rf "$SOURCE.new"
  ditto "$APP" "$SOURCE.new" && rm -f "$SOURCE.new/Icon"$'\r' \
    && { xattr -d com.apple.FinderInfo "$SOURCE.new" 2>/dev/null; true; } \
    && discard "$SOURCE" && mv "$SOURCE.new" "$SOURCE"
fi

update_source
# Keep claude:// links (sign-in callbacks) from launching the profile-less base copy
"$LSREGISTER" -u "$SOURCE" 2>/dev/null

PID=$(main_pid)
if needs_rebuild; then
  if [[ -n "$PID" ]]; then
    answer=$(osascript -e "button returned of (display dialog \"Claude $TITLE needs to restart to install Claude $(version_of "$SOURCE") and restore its logo.\" buttons {\"Later\", \"Restart Now\"} default button \"Restart Now\" with title \"Claude $TITLE\" giving up after 60)" 2>/dev/null)
    if [[ "$answer" == "Restart Now" ]]; then
      log "Restarting Claude $TITLE to update"
      quit_pid "$PID"
      PID=""
    fi
  fi
  [[ -z "$PID" ]] && rebuild
fi

if [[ -n "$PID" ]]; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
else
  open -n -a "$APP" --env CLAUDE_CONFIG_DIR="$CODE" --args --user-data-dir="$DATA"
  for i in {1..30}; do PID=$(main_pid); [[ -n "$PID" ]] && break; sleep 0.5; done
  if [[ -n "$PID" ]]; then
    log "Launched Claude $(version_of "$APP") with --user-data-dir=$DATA (pid $PID)"
  else
    log "Claude $TITLE did not start with its profile"
    notify "Did not start with its profile; see $LOG"
  fi
fi
EOF
  chmod +x "$PROFILE/launch.sh"

  echo "==> Building launcher $LAUNCHER"
  rm -rf "$LAUNCHER"
  osacompile -o "$LAUNCHER" -e "do shell script \"/bin/zsh '$PROFILE/launch.sh' > /dev/null 2>&1 &\""
  PLIST="$LAUNCHER/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"

  # Newer applets take their icon from Assets.car via CFBundleIconName; override it
  if [[ -n "$ICNS" ]]; then
    cp "$ICNS" "$LAUNCHER/Contents/Resources/applet.icns"
    rm -f "$LAUNCHER/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string applet" "$PLIST"
  fi

  codesign --force --deep -s - "$LAUNCHER"
  touch "$LAUNCHER" "$CLONE"

  # Desktop shortcut (a symlink to the launcher, so it shows the logo and
  # keeps working after the launcher is rebuilt)
  if (( DESKTOP_SHORTCUTS )); then
    SHORTCUT="$HOME/Desktop/Claude $TITLE"
    if [[ -L "$SHORTCUT" || -f "$SHORTCUT" ]]; then
      rm -f "$SHORTCUT"
    fi
    if [[ -e "$SHORTCUT" ]]; then
      echo "==> Skipping Desktop shortcut: $SHORTCUT already exists and is not a shortcut"
    else
      echo "==> Adding Desktop shortcut $SHORTCUT"
      ln -s "$LAUNCHER" "$SHORTCUT"
    fi
  fi
done

rm -rf "$CLONE_DIR/.trash" 2>/dev/null || true

# ---------- 5. Keep Claude's updater from switching accounts ----------
# Claude's built-in updater (ShipIt) replaces the app and relaunches it without
# --user-data-dir, which opens the default account instead of the profile.
# The launchers update Claude themselves, so turn the built-in one off. Claude
# reads this setting only from /Library/Managed Preferences, which needs admin.
POLICY="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
if (( UPDATER_POLICY )); then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :disableAutoUpdates' "$POLICY" 2>/dev/null)" == "true" ]]; then
    echo "==> Claude's built-in updater is already off"
  else
    echo ""
    echo "==> Turning off Claude's built-in updater (macOS will ask for your password)"
    if sudo mkdir -p "/Library/Managed Preferences" \
       && { sudo /usr/libexec/PlistBuddy -c "Set :disableAutoUpdates true" "$POLICY" 2>/dev/null \
            || sudo /usr/libexec/PlistBuddy -c "Add :disableAutoUpdates bool true" "$POLICY"; } > /dev/null \
       && sudo chmod 644 "$POLICY"; then
      echo "    Done. The launchers now install updates."
    else
      echo "    Skipped. The watchdog below still catches the updater's relaunch."
    fi
  fi
fi

# Safety net: if Claude ever starts a profile's app without its
# --user-data-dir (updater relaunch, Dock pin, opening the copy directly),
# quit it and relaunch through that profile's launcher.
WATCHDOG_DIR="$HOME/.claude-profiles"
WATCHDOG="$WATCHDOG_DIR/watchdog.sh"
AGENT_LABEL="com.claude-profiles.watchdog"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
echo "==> Installing watchdog $WATCHDOG"
mkdir -p "$WATCHDOG_DIR" "${AGENT:h}"
{
  echo '#!/bin/zsh'
  echo "LOG=\"$WATCHDOG_DIR/watchdog.log\""
  echo "typeset -A LAUNCH=("
  for NAME in $PROFILES; do
    KEY="$CLONE_DIR/Claude ${(C)NAME}.app/Contents/MacOS/Claude"
    VAL="$HOME/.claude-$NAME/launch.sh"
    echo "  ${(qq)KEY} ${(qq)VAL}"
  done
  echo ")"
  echo "BASE=${(qq)SOURCE}/Contents/MacOS/Claude"
} > "$WATCHDOG"
cat >> "$WATCHDOG" <<'EOF'

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

while true; do
  ps -axww -o pid=,args= | while read -r pid args; do
    # The hidden base copy (opened by a claude:// link, for example) has no
    # profile and would sign in to the default account; there is no profile to
    # relaunch it in, so just quit it
    if [[ "$args" == "$BASE" || "$args" == "$BASE "* ]]; then
      log "Quitting the base Claude.app (pid $pid); it opens the default account"
      kill -TERM "$pid" 2>/dev/null
      osascript -e 'display notification "Open Claude from a profile shortcut. If you were signing in, open only that profile and try again." with title "Claude opened without a profile"' 2>/dev/null
      continue
    fi
    for exe in ${(k)LAUNCH}; do
      if [[ "$args" == "$exe" || ( "$args" == "$exe "* && "$args" != *--user-data-dir=* ) ]]; then
        log "Caught ${exe:h:h:h:t} without its profile (pid $pid); relaunching through ${LAUNCH[$exe]}"
        # The launcher quits the stray copy, updates if needed, then launches
        /bin/zsh "${LAUNCH[$exe]}" > /dev/null 2>&1
      fi
    done
  done
  sleep 3
done
EOF
chmod +x "$WATCHDOG"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$WATCHDOG</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENT"

# ---------- 6. Shell aliases ----------
ZRC="$HOME/.zshrc"
touch "$ZRC"
sed -i '' '/# >>> claude-profiles >>>/,/# <<< claude-profiles <<</d' "$ZRC"
{
  echo "# >>> claude-profiles >>>"
  for NAME in $PROFILES; do
    echo "alias claude-$NAME='CLAUDE_CONFIG_DIR=\$HOME/.claude-$NAME/code claude'"
    echo "alias claude-$NAME-app='zsh \$HOME/.claude-$NAME/launch.sh'"
  done
  echo "# <<< claude-profiles <<<"
} >> "$ZRC"

killall Finder Dock 2>/dev/null || true

echo ""
echo "All done."
echo "Launch with Spotlight: $(for n in $PROFILES; do printf '"Claude %s"  ' "${(C)n}"; done)"
echo "Claude Code aliases:   $(for n in $PROFILES; do printf 'claude-%s  ' "$n"; done)"
echo "Desktop app aliases:   $(for n in $PROFILES; do printf 'claude-%s-app  ' "$n"; done)"
echo "Open a new terminal (or run: source ~/.zshrc) to use the aliases."
