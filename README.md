<img src="./app-icon.png" width="80" alt="Diction">

# Diction

A dictation app for macOS. Hold fn while you talk; when you let go, Diction types the text where your cursor is.

- Speech recognition runs on the Mac (Parakeet v3).
- With an Anthropic API key, Claude Haiku cleans up the transcript. Without one, a small model on the Mac does it.
- The window has History, Meetings, Dictionary, Swaps and Style. Settings open in their own window.

Build and restart with `../build.sh` from the parent folder. Notes on the current state are in `../HANDOFF.md`.
