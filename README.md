<img src="./app-icon.png" width="80" alt="Diction">

# Diction

Diction is a dictation app for macOS. Hold fn and talk; when you let go, it types what you said wherever your cursor is. For longer stretches, press fn + Space to dictate hands-free and fn again to finish. Esc cancels.

- Speech recognition runs on your Mac with Parakeet v3, which knows 25 languages. Diction downloads the model the first time it starts.
- With an Anthropic API key, Claude Haiku cleans up each dictation. It takes out filler words, fixes punctuation, and turns "Friday at three, no, four" into "Friday at four". The audio stays on your Mac; only the text goes to Anthropic. Without a key, a small model on your Mac does the cleanup, downloaded the first time it's needed.

## The window

- History lists everything you dictated. Click a line to copy it.
- Meetings records calls and transcribes them on your Mac.
- Dictionary is for names and words Diction should spell your way.
- In Swaps, a short spoken phrase turns into a longer text, such as your address or a link you send often.
- Style decides how the text comes out: formal, casual, very casual or excited.

Settings open from the sliders icon, or with ⌘,.

## Permissions

The first-run window asks for three:

- the microphone, to hear what you say
- Accessibility, to paste into the app you're using
- Input Monitoring, to notice when you hold fn

Meetings also needs Screen Recording to hear the other side of a call, and so does "Read the window you dictate into" in Settings.

## Build

You need a Mac with Apple Silicon, macOS 14 or later, and Xcode 27.

```bash
git clone https://github.com/bendrape1-byte/Diction.git
cd Diction
xcodebuild -scheme Diction -configuration Release ARCHS=arm64 -derivedDataPath build \
  CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -skipPackagePluginValidation -skipMacroValidation build
open build/Build/Products/Release/Diction.app
```

`CODE_SIGN_IDENTITY=-` signs the app without an Apple account. macOS then treats each rebuild as a new app and asks for the permissions again. To keep them across rebuilds, sign with your own team: replace `CODE_SIGN_IDENTITY=-` with `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<your team ID>`. Xcode shows your team ID under Settings → Accounts.

## API key and prompt

Paste your Anthropic API key into Settings → Cleanup. Diction stores it in the macOS Keychain.

Haiku follows a short set of built-in rules. To use your own instructions instead, put a file named `haiku_prompt.txt` in `~/Library/Application Support/Diction/`. It helps to include a few of your own dictations, each next to the way you would have typed it, so the cleanup matches how you write.

## Your data

Dictations, the dictionary and settings stay in `~/Library/Application Support/Diction/`. Meeting transcripts go to `~/Documents/Diction Meetings/`.

## License

MIT, see [LICENSE](LICENSE). [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) credits the code and the font that come from other projects.
