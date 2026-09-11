#!/bin/sh
# win64-windres-wrapper.sh - MinGW windres wrapper for cross-building OpenSSL.
#
# windres does not inherit gcc's include search path and does not define _WIN32,
# so compiling OpenSSL's .rc resource file fails with a missing winver.h. The
# cross build installs this wrapper as `windres` ahead of the real tool; the
# steps live in docs/windows-mingw-build-guide.md under "Linux MinGW 交叉编译",
# and are still run by hand -- there is no build-win64-linux.sh in this repo.
#
# Recovered verbatim from the 2026-09-10 cross build (/tmp/winbin/windres).

exec "$HOME/.local/mingw/usr/bin/x86_64-w64-mingw32-windres" \
    -D_WIN32 \
    -I"$HOME/.local/mingw/usr/x86_64-w64-mingw32/include" \
    "$@"
