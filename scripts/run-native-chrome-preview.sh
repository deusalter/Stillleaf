#!/bin/bash
set -euo pipefail

# SwiftUI follows macOS Keyboard Navigation for button focus. Enable it for
# this isolated native keyboard check, then restore the runner's preference.
# Do not change the app's focus policy or feed a synthetic isFocused value.
had_keyboard_mode=false
if keyboard_mode=$(defaults read -g AppleKeyboardUIMode 2>/dev/null); then
  had_keyboard_mode=true
fi
had_reduce_transparency=false
had_reduce_motion=false
prepare_system_glass=false
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # Hosted macOS runners disable both effects globally. A SwiftUI preview
  # environment override cannot override native NavigationSplitView glass.
  prepare_system_glass=true
  if reduce_transparency=$(defaults read com.apple.universalaccess reduceTransparency 2>/dev/null); then
    had_reduce_transparency=true
  fi
  if reduce_motion=$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null); then
    had_reduce_motion=true
  fi
fi
restore_preferences() {
  if "$had_keyboard_mode"; then
    defaults write -g AppleKeyboardUIMode -int "$keyboard_mode"
  else
    defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
  fi
  if "$prepare_system_glass"; then
    if "$had_reduce_transparency"; then
      defaults write com.apple.universalaccess reduceTransparency -bool "$reduce_transparency"
    else
      defaults delete com.apple.universalaccess reduceTransparency >/dev/null 2>&1 || true
    fi
    if "$had_reduce_motion"; then
      defaults write com.apple.universalaccess reduceMotion -bool "$reduce_motion"
    else
      defaults delete com.apple.universalaccess reduceMotion >/dev/null 2>&1 || true
    fi
  fi
}
trap restore_preferences EXIT
defaults write -g AppleKeyboardUIMode -int 3
if "$prepare_system_glass"; then
  defaults write com.apple.universalaccess reduceTransparency -bool false
  defaults write com.apple.universalaccess reduceMotion -bool false
  # Checked through NSWorkspace in the newly launched app, rather than
  # assuming defaults changed what AppKit's compositor actually observes.
  STILLLEAF_PREVIEW_EXPECT_SYSTEM_GLASS=1 "$1" --render-native-chrome "$2"
else
  "$1" --render-native-chrome "$2"
fi
