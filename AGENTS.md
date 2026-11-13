# wechat-duo

macOS menu bar app (Swift / SwiftUI) that creates and maintains a second WeChat copy. Usage: [README.md](README.md). Keep all repo content in English.

- **Verify changes**: `swift test` → `scripts/build.sh` → install `dist/WeChat Duo.app` to `/Applications` → `--cli status`
- **Release**: push a `v*` tag; `.github/workflows/release.yml` builds and publishes the dmg

## Invariants

- `/Applications/WeChat.app` is read-only; no code path writes to it
- `~/Library/Containers/com.tencent.xin2` (the copy's chat data) is only trashed after the user ticks the box and confirms; every other removal also goes to the Trash (`trashItem`), never `removeItem`
- Quit the copy before re-signing; start it by executing `Contents/MacOS/WeChat` directly, never via `open`
- Never write `~/Library/LaunchAgents`; open-at-login uses `SMAppService.mainApp` only
- After changing the copy, always run `refreshCaches()` (touch .app / Contents / Info.plist, `lsregister -f`, restart iconservicesagent and Dock), or the Dock keeps the old icon
- Our own changes emit FSEvents; `Healer` filters them via `isBusy` / `lastOwnWrite`, so every operation that modifies the copy must go through `CopyManager.exclusive`
