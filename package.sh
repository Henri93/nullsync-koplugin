#!/bin/sh
# Build the release zip KOReader users unpack into koreader/plugins/
set -e
cd "$(dirname "$0")"
rm -f nullsync.koplugin.zip
zip -r -q nullsync.koplugin.zip nullsync.koplugin -x "*.DS_Store"
echo "built nullsync.koplugin.zip ($(du -h nullsync.koplugin.zip | cut -f1))"
