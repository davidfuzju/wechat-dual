# WeChat Duo

A tiny macOS menu bar app for running two WeChat accounts side by side. It makes a second copy of WeChat, keeps it working after WeChat updates overwrite it, and lets you pick its icon color. No Terminal, no Python.

## Install

1. Download `WeChatDuo-x.y.z.dmg` from [Releases](../../releases) and drag **WeChat Duo** into Applications.
2. First launch: **right-click → Open → Open** (the app is not notarized by Apple).
3. Choose **Create Copy & Open at Login**. A copy named `WeChat Dual` appears in `~/Applications` and starts; log in to your second account there.

Requires WeChat in `/Applications/WeChat.app`. The original app is never modified.

## Use

Click the chat-bubble icon in the menu bar to see the copy's status, version and whether it's running, and to start, quit or repair it. **Settings…** lets you change the icon color (with live preview), rename the copy, and toggle open-at-login and auto-repair.

When WeChat's built-in updater overwrites the copy, WeChat Duo notices within seconds, repairs it and shows a notification.

## Uninstall

Settings → **Uninstall…**. The copy, WeChat Duo, its login item and settings go to the Trash. The copy's chat data (`~/Library/Containers/com.tencent.xin2`) is kept unless you tick the box and confirm.

## How it works

macOS tells apps apart by bundle ID. The copy gets its own ID (`com.tencent.xin2`) and an ad-hoc signature, so it runs alongside the original with separate data. WeChat's updater replaces the copy with the official build, so instead of blocking updates WeChat Duo watches `~/Applications` and re-applies the name, ID, icon and signature afterwards.

## Disclaimer

Unofficial; not affiliated with or endorsed by Tencent. WeChat is a trademark of Tencent. Running a modified, re-signed copy of WeChat may violate its terms of service and could put your account at risk — use at your own risk. This project ships no WeChat code or artwork; the copy is made on your Mac from the WeChat you installed. Provided "as is", without warranty (see [LICENSE](LICENSE)).

## Development

```bash
swift test          # unit tests
scripts/build.sh    # builds dist/WeChat Duo.app and the dmg
git tag v0.1.1 && git push origin v0.1.1   # CI builds the dmg and publishes a Release
```

Logic lives in `Sources/DuoCore`, the menu bar UI in `Sources/WeChatDuo`. Troubleshooting: `"/Applications/WeChat Duo.app/Contents/MacOS/WeChatDuo" --cli status`; log at `~/Library/Logs/WeChatDuo.log`.

Based on [forest-USTC/wechat-dual-launcher](https://github.com/forest-USTC/wechat-dual-launcher) (MIT), rewritten in Swift.
