#!/bin/sh

rm -fr zig-out
rm -fr .zig-cache
# 必须用稳定的开发者证书签名（DN3HDD448D），否则 ad-hoc 签名每次构建都变，
# macOS 的「本地网络」等隐私授权会丢失，导致 ssh 无法连接局域网主机。
GHOSTTY_SIGN_TEAM=DN3HDD448D zig build -Doptimize=ReleaseSmall

