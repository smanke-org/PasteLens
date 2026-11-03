---
name: pastelens
description: Drive PasteLens, the clipboard history app on this Mac, from the shell with the `pastelens` command: search and read clippings, save text as a clipping, pin clippings and move them into pastebins, copy one to the clipboard, run filters (Title Case, Base64 and the rest) on text, expand snippets, and pause recording. Use when the user asks about something they copied, wants a clipping found, saved, filed or copied, wants text run through a PasteLens filter, or names PasteLens.
---

# PasteLens

`pastelens` runs commands in the PasteLens app. Changes show in its windows at once. If the
app is closed, the command opens it in the background. If `pastelens` isn't on PATH, use
`/Applications/PasteLens.app/Contents/MacOS/PasteLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Find ids with `pastelens clips list --search ...`. An id is 8 characters; any unique start works.
- Clippings with `"sensitive": true` look like secrets: their text is never returned. Don't
  try to get it another way; the person can see it in PasteLens.
- `clips delete` and `history clear` only report what they would delete. Show the user that
  report and ask before you run it again with `--yes`: it can't be undone and goes from every
  Mac that syncs.
- `clips copy` replaces what's on the person's clipboard. Only run it when they asked.
- `filters run` runs the filter's steps; a filter with a shell script, JavaScript or AI step
  runs that too. Check its steps in `pastelens filters list` first if you're unsure.
- The hyphenated commands (`get-clippings`, `paste-clipboard`, …) are the older tool's. Prefer
  the commands in `pastelens help`; never paste into apps unless the person asked.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/pastelens-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `pastelens status --json` | Version, paused or not, clipping counts, stack size, sync status |
| `pastelens clips list [--search T] [--pastebin NAME] [--since DATE] [--limit N] --json` | Find clippings (search forgives typos) |
| `pastelens clips show <id> --json` | One clipping, with its full text |
| `pastelens clips add --text T [--title T] [--pastebin NAME] --json` | Save text as a clipping (clipboard untouched) |
| `pastelens clips update <id> [--note T] [--pinned true/false] --json` | Change one |
| `pastelens clips move <ids> --to NAME\|history --json` | File clippings into a pastebin |
| `pastelens filters run "<filter>" --text T --json` | Run a filter and get the result |

Everything else: `pastelens help`, and `pastelens help <command>` for its options.
