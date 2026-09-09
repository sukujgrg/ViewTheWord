# Follow-up work

See the [architecture guide](docs/architecture.md) for the current design and validation coverage.

- Complete the [manual macOS and external-display validation](docs/manual-validation.md), especially VoiceOver/focus, rapid Escape/reopen, HDMI reconnect, fullscreen Spaces, and Finder import.
- Profile the search matcher with a large imported library. Consider FTS only if the existing matcher becomes a measured bottleneck, with tokenizer tests for Malayalam combining marks and other supported scripts.
- Profile the native verse tables and adaptive chapter grid during prolonged rapid navigation, live resizing, and large imported chapters; automated native-event and offscreen layout checks cover navigation and wrapping regressions.
- Explore a reading-size warning or splitting exceptionally long verses across slides if venue testing shows automatic fitting is too small to read.
