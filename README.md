# PasteLens

**A free clipboard manager for the Mac.** PasteLens remembers everything you copy so you can find it and paste it again with one shortcut. It can clean up or transform text before pasting, queue several clippings to paste in order, and keep your history in sync across your Macs. Anything it stores in iCloud is end-to-end encrypted.

There's no subscription, no license key and no account.

## Download

### ⬇️ [Download PasteLens.dmg](https://github.com/smanke-org/PasteLens/releases/latest/download/PasteLens.dmg)

1. Open the DMG.
2. Drag **PasteLens** to **Applications**.
3. Open PasteLens. When macOS asks, allow **Accessibility** so it can paste into other apps.

Requires macOS 26 or later.

## What it does

- **History**: everything you copy, including text, rich text, links, colors, images and files, ready to paste again. You choose how many clippings to keep by typing a number (0 keeps everything) and, optionally, how many days.
- **Quick Paste (⇧⌘V)**: search and paste from any app. Search tolerates typos. ⌘1–⌘9 paste directly, ⇧↩ pastes plain text, ⌥↩ types the text out for fields that block pasting, and Tab switches pastebins. There's an optional "release to paste" mode that works like ⌘⇥.
- **Pastebins and smart pastebins**: save clippings you want to keep. Smart pastebins collect clippings automatically by rules such as kind, text, source app, size or age.
- **Filters (⌘↩ in Quick Paste)**: 50+ built in, including case styles, encoding, find and replace with a live regex tester, line operations, JSON, Markdown, HTML, translation and Apple Intelligence (summarize, fix grammar, rewrite). You can also build your own from steps, including JavaScript and shell scripts, and give any filter its own shortcut.
- **Stack**: queue clippings and paste them one after another with ⌃⇧⌘V. "Collect" mode adds each copy as you go.
- **Snippets**: reusable text with placeholders such as `{date:yyyy-MM-dd}`, `{clipboard}`, `{input:Name}` and `{cursor}`. Snippets can expand from typed abbreviations (optional).
- **Smart clipboard**:
  - Text in screenshots and images is recognized on your Mac, so you can search it.
  - Colors get swatches in every notation.
  - Links show a preview.
- **Secrets stay secret**: API keys, private keys, card numbers, one-time codes and password-like text are hidden, never synced, and deleted after a few minutes. Copies that password managers mark as private are never recorded.
- **Encrypted sync**: history, pastebins, filters, snippets and settings sync through iCloud. Every record is sealed with AES-256-GCM on your Mac. The key is protected by a passphrase that never leaves your Macs.
- **Automation**:
  - Shortcuts actions.
  - A `pastelens` command-line tool.
  - An MCP server for AI assistants.
  - `pastelens://` URLs.
- **Import**: brings over Pastebot clippings, pastebins and `.pastebotfilter` files.

## Sync and encryption

Turn on sync in **Settings › Sync** and choose a passphrase. Enter the same passphrase on your other Macs.

- PasteLens syncs through CloudKit, Apple's iCloud database, one small record per change. Other Macs fetch only what changed, and iCloud tells them when there's something new.
- A random 256-bit key seals every record and every clipping's bytes with AES-256-GCM before they leave your Mac. Apple only sees record names, dates and ciphertext.
- That key is stored in iCloud only after being wrapped with a key derived from your passphrase (PBKDF2-SHA256, 600,000 rounds). On each Mac, the key is kept in the login keychain.
- When two Macs change the same thing, the newer change wins on every Mac. Deletions travel as records too, so a Mac that was offline can't bring something back.
- Secrets and clippings over the size limit you set stay on the Mac where they were copied.

## Storage

Clippings are kept in an SQLite database with a full-text index (`~/Library/Application Support/PasteLens/PasteLens.sqlite`), and each clipping's bytes are kept in its own file beside it. Lists load a page at a time and search uses the index, so PasteLens stays quick with tens of thousands of clippings. Versions before 1.0.6 kept a `library.json`; it's moved into the database automatically and the old file is kept as `library-before-database.json`.

## Command line and MCP

In **Settings › Advanced**, copy the install command for the `pastelens` tool, or the MCP configuration for Claude Desktop or another MCP client.

```bash
pastelens get-clippings --query invoice --limit 5
pastelens apply-filter --filter-id "Title Case" --text "the quick brown fox"
pastelens write-to-pasteboard --text "Hello" && pastelens paste-clipboard
pastelens help
```

## Updates

The GitHub version checks for new releases. In **Settings › General** you choose whether updates install automatically, whether it asks first, or whether it never checks. Each download's signature and notarization are verified before it is installed.

## Building

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
swift test          # PasteLensKit: filters, encryption, database, sync merge, import, bridge
./build_app.sh      # archive, then export for Developer ID with the CloudKit provisioning profile
./release.sh 1.0.1  # build, notarize, DMG, GitHub release
```

`project.yml` defines the app and its two helper tools. The **AppStore** configuration builds a sandboxed version with no updater, which syncs through PasteLens's own iCloud container. Archive it from Xcode with automatic signing.

## License

© 2026 Steve Manke.
