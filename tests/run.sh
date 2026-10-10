#!/bin/sh
# Syntax-check every Lua file and run the podcast logic harness under plain Lua
# (KOReader uses LuaJIT; `lua` 5.4 is stricter, which is what we want in CI).
set -e
cd "$(dirname "$0")/.."
luac -p nullsync.koplugin/*.lua
PLUGIN_DIR="$PWD/nullsync.koplugin" lua tests/podcast_harness.lua
