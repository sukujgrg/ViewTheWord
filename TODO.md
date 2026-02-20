# TODO

- Projection update path: keep projector content updates immediate (`VerseRowView` -> `MainView` -> `ProjectorViewModel`) for arrow-key navigation responsiveness.
- Network mirror path: add debounce/throttle only around `sendTextOverNetwork(...)` in `ProjectorView` to avoid flooding external display/API updates during rapid verse navigation.
