#!/usr/bin/env bash
# macOS defaults. Run directly, or via `sys setup` / `sys sync`.
#
# Only settings that differ from macOS's own defaults are here — writing a
# value the system already uses is noise. See `man sys`.
source "$HOME/.sys/lib/common.sh"

# Stop System Settings overwriting what we're about to change. killall rather
# than osascript: telling an app to quit needs Automation permission, which
# makes macOS throw a "wants access to control System Events" dialog.
killall "System Settings" 2>/dev/null || true

# ── General ──────────────────────────────────────────────────────────────────
# Sidebar icons small. 1 = small, 2 = medium (the macOS default), 3 = large.
defaults write NSGlobalDomain NSTableViewDefaultSizeMode -int 1
defaults write NSGlobalDomain AppleShowScrollBars -string "WhenScrolling"
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false

# Expand save and print panels by default
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true

# No autocorrect, smart quotes or smart dashes — they mangle code.
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# Keyboard and trackpad live in config/input — applied on every sync.

# ── Screenshots ──────────────────────────────────────────────────────────────
defaults write com.apple.screencapture disable-shadow -bool true

# ── Finder ───────────────────────────────────────────────────────────────────
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# Open windows in column view. Folders with their own saved view keep it.
defaults write com.apple.finder FXPreferredViewStyle -string "clmv"
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
chflags nohidden ~/Library || true

# Full path in the title bar. Handy, but screenshots then reveal your
# home-directory structure.
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

# ── Dock ─────────────────────────────────────────────────────────────────────
defaults write com.apple.dock tilesize -int 36
defaults write com.apple.dock mru-spaces -bool false
# Click wallpaper to show desktop: only in Stage Manager. macOS offers just
# Always (true, the default) or this — no Off or Command-click option.
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false

# ── Other ────────────────────────────────────────────────────────────────────
defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true
# Safari: tick "Show features for web developers" (Settings → Advanced), which
# brings back the Develop menu. Safari's prefs live in its sandbox container, so
# this needs Full Disk Access for the terminal running the script, and Safari
# rewrites the file when it quits — close Safari first, or it may not stick.
defaults write com.apple.Safari IncludeDevelopMenu -bool true
# Mail: Control-A archives the selected message. Applies next time Mail opens.
defaults write com.apple.mail NSUserKeyEquivalents -dict-add "Archive" "^a"
defaults write org.m0k.transmission UseIncompleteDownloadFolder -bool true
defaults write org.m0k.transmission IncompleteDownloadFolder -string "$HOME/Downloads/Torrents"

# ── Apply ────────────────────────────────────────────────────────────────────
for app in cfprefsd Dock Finder SystemUIServer; do
  killall "$app" &>/dev/null || true
done

doing "macOS defaults applied — some need a logout to take effect"
