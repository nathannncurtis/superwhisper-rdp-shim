**What changed and why**

**Related issues**

**How you tested it**

Input handling is hard to unit test and easy to break in ways that only show up
in a live session. If you touched the event tap or the typist, say which remote
client you tested against and what you dictated.

**Checklist**
- [ ] Focused on a single change
- [ ] Builds with `./build.sh`
- [ ] Existing behaviour still works — including that a normal Cmd+V, and
      Superwhisper pasting into a non-remote app, are untouched
