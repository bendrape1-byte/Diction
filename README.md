<img src="./app-icon.png" width="80" alt="Diction">

# Diction

A dictation app for macOS. Hold a shortcut, talk, let go, and the text is typed wherever your cursor is, in any app.

- **Speech recognition runs on your Mac** (Parakeet v3). Your audio never leaves it.
- **Cleanup with Claude Haiku** removes filler words and fixes punctuation. You use your own Anthropic API key, and it costs less than 1 cent per 1,000 words dictated.
- **Or completely free and local:** choose Local only and a small model on your Mac does the cleanup. Nothing leaves your Mac, but it's noticeably worse than Haiku.

## Features

- Hold to talk, or hands-free mode. Esc cancels.
- A small pill under the menu bar that moves with your voice.
- Cleanup levels Off, Light and Medium; styles Formal, Casual, lowercase and Excited.
- Reads the window you're dictating into, so names on screen are spelled right (optional).
- Dictionary for names and jargon, plus fixes like "clawed → Claude". Fix a word after it's pasted and Diction learns it.
- Swaps: say a short phrase, get a longer text typed, like your address or a link.
- Searchable history of everything you've dictated.
- Meeting notes: records your mic and the call, labels "Me" and "Others", transcribes on your Mac and saves Markdown files. Can offer to start when a Zoom, Teams, Meet, FaceTime, Webex, Slack or Discord call begins.
- Pauses music and video while you dictate.
- Languages: English, German, Spanish, French, Italian, or automatic.

## Build and run

You need macOS 14 or later and Xcode 16 or later.

1. Clone the repo and open `Diction.xcodeproj`.
2. Pick your signing team: select the Diction target, then Signing & Capabilities, then your team.
   Or copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set `DEVELOPMENT_TEAM` there.
3. Press ⌘R. Xcode fetches the Swift packages on the first build.

On first launch Diction asks how to clean up your dictations (Claude Haiku or Local only) and for three permissions (Microphone, Accessibility, Input Monitoring). It downloads the speech model and a small cleanup model (about 0.5 GB). After that it works offline.

## Use

- **Hold to talk:** Right ⌘ + Right ⌥. Release to paste.
- **Hands-free:** Right ⌘ + Right ⌥ + Space. Press again, or click the pill, to finish.
- Both shortcuts can be changed in Settings (⌘, in the Diction window).

To use Claude Haiku, paste your Anthropic API key during setup or in Settings. Get one at [platform.claude.com](https://platform.claude.com/settings/keys). The key stays in your Mac's Keychain. Only the transcript text goes to Anthropic, plus the text read from your window if that option is on. Switch between Claude Haiku and Local only any time in Settings → Cleanup.

Haiku's instructions live in `~/Library/Application Support/Diction/haiku_prompt.txt`. Diction writes a general version there on first launch; edit it to tune the cleanup to how you talk.

## Credit

Diction started as a fork of [Ghost Pepper](https://github.com/matthartman/ghost-pepper) by Matt Hartman. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT, see [LICENSE](LICENSE).
