# nullsync.koplugin

A [KOReader](https://koreader.rocks) plugin that extends your progress-sync account with three things the stock sync doesn't do:

- **Vocabulary backup.** Words you save in KOReader's vocabulary builder are copied to your sync server, with the sentence they came from.
- **Highlights and notes backup.** The current book's highlights and notes are copied on close and on suspend. Deleting on the device deletes on the server; the device is the source of truth.
- **Reading Recap podcast.** When you close a book, the plugin extracts the passage you read since the last episode, right on the device, and sends it to your server, which turns it into a spoken podcast episode about those exact pages. The server keeps the episode, never the book.

It reuses the account and server you already configured under **Progress sync**, so there is nothing new to log in to.

The plugin talks to the open-source [reader-progress](https://github.com/Henri93/reader-progress) server. The hosted one at `https://api.null-space.xyz` is free to use for sync; the podcast is a paid add-on at https://www.null-space.xyz/reader/podcast.

## Install

1. Download `nullsync.koplugin.zip` from the [latest release](https://github.com/Henri93/nullsync-koplugin/releases/latest) and unzip it.
2. Copy the `nullsync.koplugin` folder into `koreader/plugins/` on your device. On a Kindle that's over USB; on Android it's the `koreader/plugins` folder in the app's storage.
3. Restart KOReader.
4. Make sure **Progress sync** is set up with a custom server (`https://api.null-space.xyz` or your own) and that you are logged in.
5. Open the tools menu, then **Null-space sync**. Vocabulary and highlights sync is on by default. The podcast is off until you turn it on.

Works with KOReader 2024.x and newer on every platform KOReader runs on (Kindle, Kobo, PocketBook, reMarkable, Android, Linux, macOS).

## Reading Recap: how the podcast part works

- When a book is opened, the plugin remembers where you are. That is the start of the next episode.
- When you close the book or the device sleeps, if you've read at least 2 percent more (configurable) and it has been at least four hours since the last episode, the plugin extracts the text between the two positions with KOReader's own text APIs and `POST`s it to `/podcast/ingest` with your sync credentials.
- The server writes a script about those pages following the instructions you set on the website, synthesizes audio, and adds the episode to your private RSS feed. The passage is used once and discarded.
- **Make an episode from what I've read now** forces an episode immediately. **Start the next episode from here** resets the window.

Nothing is sent unless the podcast toggle is on, and only the text between the two positions ever leaves the device. Works for EPUB and other reflowable books (xpointer ranges) and for PDF and other page-based books (page ranges).

## Development

```sh
./tests/run.sh    # luac syntax check + logic harness (needs lua 5.4 and luac)
./package.sh      # build the release zip
```

Layout:

| File | Purpose |
|---|---|
| `nullsync.koplugin/_meta.lua` | Plugin metadata KOReader reads |
| `nullsync.koplugin/main.lua` | Settings, menu, HTTP helper, vocabulary and highlight sync, event hooks |
| `nullsync.koplugin/podcast.lua` | Position markers, on-device text extraction, episode trigger and payload |
| `tests/podcast_harness.lua` | Runs `podcast.lua` against fake EPUB and PDF documents under plain Lua |

Server endpoints used: `PUT /syncs/vocabulary`, `PUT /syncs/annotations`, `POST /podcast/ingest`. All take the same `x-auth-user` / `x-auth-key` headers as KOReader's progress sync.

## License

GPL-3.0, same as the reader-progress server. KOReader itself is AGPL-3.0.
