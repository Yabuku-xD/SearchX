SearchX for Linux — early preview

A first shell of SearchX over GTK 4 and WebKitGTK: tabs across the top, one
field for addresses and searches, the built-in ad blocker, and your tabs back
at the next launch. The Mac version's other features are not here yet; see
PORTING.md in the repository for what comes next.

It needs GTK 4 and WebKitGTK 6.0:

  Ubuntu 24.04 or Debian 13:  sudo apt install libgtk-4-1 libwebkitgtk-6.0-4
  Fedora:                     sudo dnf install gtk4 webkitgtk6.0
  Arch:                       sudo pacman -S gtk4 webkitgtk-6.0

Run it from this folder:

  ./searchx

Or install it for your user, with its icon in your app launcher:

  install -Dm755 searchx ~/.local/bin/searchx
  install -Dm644 searchx.png ~/.local/share/icons/hicolor/256x256/apps/searchx.png
  install -Dm644 searchx.desktop ~/.local/share/applications/searchx.desktop

Its tabs, cookies and settings are kept in ~/.local/share/searchx.

Built by Shyamalan Kannan. MIT licensed, see LICENSE.
