#!/bin/bash
set -euo pipefail

# SwiftUI follows macOS Keyboard Navigation for button focus. Enable it for
# this isolated native keyboard check, then restore the runner's preference.
# Do not change the app's focus policy or feed a synthetic isFocused value.
had_keyboard_mode=false
if keyboard_mode=$(defaults read -g AppleKeyboardUIMode 2>/dev/null); then
  had_keyboard_mode=true
fi
restore_keyboard_mode() {
  if "$had_keyboard_mode"; then
    defaults write -g AppleKeyboardUIMode -int "$keyboard_mode"
  else
    defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
  fi
}
trap restore_keyboard_mode EXIT
defaults write -g AppleKeyboardUIMode -int 3
"$1" --render-native-chrome "$2"
