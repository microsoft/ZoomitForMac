#!/bin/zsh
# Resets ZoomIt to a clean "first run" state for testing the onboarding and
# permission-prompt experience.
#
# It quits any running bundle, clears the app's privacy permissions (Screen
# Recording, Microphone, Camera) so the system prompts appear as they would for
# a new user, and optionally wipes the saved settings so hotkeys and other
# preferences return to their defaults.
#
# Usage:
#   zsh Scripts/reset-first-run.sh           # reset permissions + settings, then relaunch
#   zsh Scripts/reset-first-run.sh --keep-settings   # keep saved settings
#   zsh Scripts/reset-first-run.sh --no-launch       # don't relaunch afterwards
#
# Note: test first run with the .app bundle (build it with Scripts/build-app.sh),
# not `swift run`. The build script ad-hoc signs the bundle with a stable local
# designated requirement so privacy grants attach to the bundle identifier.

set -euo pipefail

BUNDLE_ID="com.sysinternals.zoomitmac"
ROOT_DIR="${0:A:h:h}"
APP_PATH="$ROOT_DIR/.build/ZoomIt.app"

keep_settings=false
launch=true
for arg in "$@"; do
    case "$arg" in
        --keep-settings) keep_settings=true ;;
        --no-launch) launch=false ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

echo "Quitting any running ZoomIt instance…"
pkill -f "ZoomIt.app/Contents/MacOS/ZoomIt" 2>/dev/null || true
sleep 1

echo "Resetting privacy permissions (Screen Recording, Microphone, Camera) for $BUNDLE_ID…"
# `reset All` clears every TCC service this app may have been granted.
tccutil reset All "$BUNDLE_ID" || true
# Older development bundles were only executable-signed and appeared to TCC as
# "ZoomIt" instead of the bundle identifier. Clear that stale identity too so
# the Screen Recording list doesn't show an enabled row that no longer matches
# the current app's code requirement.
tccutil reset All "ZoomIt" >/dev/null 2>&1 || true

if [[ "$keep_settings" == false ]]; then
    echo "Clearing saved settings (UserDefaults) for $BUNDLE_ID…"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
else
    echo "Keeping saved settings."
fi

if [[ "$launch" == true ]]; then
    if [[ -d "$APP_PATH" ]]; then
        echo "Relaunching $APP_PATH …"
        open "$APP_PATH"
        echo "Grant Screen Recording when prompted, then quit and reopen ZoomIt once."
    else
        echo "App bundle not found at $APP_PATH."
        echo "Build it first with: zsh Scripts/build-app.sh release"
        exit 1
    fi
else
    echo "Done. Launch the app manually with: open \"$APP_PATH\""
fi
