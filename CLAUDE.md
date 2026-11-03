# PasteLens

Drive the app with `pastelens` (the app binary; `pastelens help`). See `.claude/skills/pastelens/SKILL.md`. Commands live in
`App/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which starts a test copy on its
own clippings and settings with no sync, keychain, clipboard watching or shortcuts (Release builds ignore it). Never add a
build target or product named `pastelens` for it: the existing helper in `Contents/Helpers` already has that name.
