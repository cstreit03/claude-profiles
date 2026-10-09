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
#   5. Adds aliases to ~/.zshrc for each profile:
#        claude-<name>       Claude Code (CLI) in that profile
#        claude-<name>-app   Opens or focuses that profile's Desktop app
#
# Updating Claude later: download it, drag it into /Applications, run this again.
# Custom profile list: ./setup.sh work personal clientx

set -euo pipefail

MIGRATE_TO=""             # no migration unless --migrate-to is given
DESKTOP_SHORTCUTS=1       # Desktop shortcuts unless --no-desktop is given
ICON_PAD=1                # shrink PNG logos onto Apple's icon grid unless --no-icon-pad
ICON_ART=824              # artwork size on the 1024px canvas (Apple's grid is 824)
PROFILES=()

usage() {
  echo "Usage: ./setup.sh [--migrate-to <profile>] [--no-desktop] [--no-icon-pad] [profile ...]"
  echo "  --migrate-to <profile>  Copy your existing Claude login and ~/.claude into this profile"
  echo "                          (default: no migration, every profile starts fresh)"
  echo "  --no-desktop            Do not put shortcuts on the Desktop"
  echo "  --no-icon-pad           Use PNG logos as-is (if they already include padding)"
  echo "  profile ...             Profiles to create (default: work personal)"
  exit 1
}

while (( $# )); do
  case "$1" in
    --migrate-to)   [[ -n "${2:-}" ]] || usage; MIGRATE_TO="$2"; shift 2 ;;
    --migrate-to=*) MIGRATE_TO="${1#*=}"; shift ;;
    --no-desktop)   DESKTOP_SHORTCUTS=0; shift ;;
    --no-icon-pad)  ICON_PAD=0; shift ;;
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
  rm -rf "$CLONE"
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
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$CLONE/Contents/Info.plist" > "$PROFILE/.icon-version" 2>/dev/null || true
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
ICON="$ICON"
LOG="$PROFILE/launch.log"
STAMP="$PROFILE/.icon-version"
EOF
  cat >> "$PROFILE/launch.sh" <<'EOF'

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Claude's auto-updater replaces the whole clone, which drops the custom logo
# (stored in the bundle's "Icon\r" file). Reapply it when that file is missing
# or the app version changed since the logo was last applied.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null)
if [[ -n "$ICON" && -f "$ICON" ]] && [[ ! -e "$APP/Icon"$'\r' || "$(cat "$STAMP" 2>/dev/null)" != "$VERSION" ]]; then
  # setIcon returns false instead of throwing when macOS blocks the write
  # (App Management privacy setting), so turn that into a real error.
  if osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) {
      const img = $.NSImage.alloc.initWithContentsOfFile(a[0])
      if (!img || img.isNil() || !$.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, a[1], 0)) throw new Error("setIcon was refused")
    }' "$ICON" "$APP" >> "$LOG" 2>&1; then
    print -r -- "$VERSION" > "$STAMP"
    touch "$APP"
    log "Reapplied logo (Claude $VERSION)"
  else
    log "Could not reapply logo to $APP. Allow \"Claude $TITLE\" in System Settings > Privacy & Security > App Management, or rerun setup.sh."
    osascript -e "display notification \"Allow Claude $TITLE in Privacy & Security > App Management, or rerun setup.sh.\" with title \"Could not restore the Claude $TITLE logo\"" 2>/dev/null
  fi
fi

# Main process only (helpers run a different binary, so they do not match)
PID=$(pgrep -f "Contents/MacOS/Claude --user-data-dir=$DATA" | head -1)

if [[ -n "$PID" ]]; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
else
  open -n -a "$APP" --env CLAUDE_CONFIG_DIR="$CODE" --args --user-data-dir="$DATA"
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

# ---------- 5. Shell aliases ----------
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
