# Package

description = "Macro-oriented asynchronous web-framework written with ♥"
author = "HapticX"
version = "0.26.0"
license = "GNU GPLv3"
srcDir = "src"
installExt = @["nim"]
bin = @["hpx"]

# Deps

requires "nim >= 1.6.12"
requires "cligen"
requires "regex"
requires "httpx"
requires "illwill"
requires "nimja"
requires "websocketx"
