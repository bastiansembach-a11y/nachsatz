# Contributing

Issues and pull requests are welcome in English or German.

## Reporting an app that does not work

Open the Nachsatz menu in that app and copy the line "Zuletzt: …". Useful details: app and version, kind of field, what you expected. The log helps and contains no text:

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "local.nachsatz.read"'
```

It does list which apps you typed in, so look through it before posting. Never post `memory.bin` or private text.

## Working on the code

- Keep `NachsatzCore` free of UI and AppKit windows.
- Without full Xcode the `@State` macro is missing. Use `@Local` (see `Theme.swift`).
- Never call Accessibility from the main thread, except for Nachsatz's own windows.
- Never log text. Lengths, roles and timings are fine.
- Do not work around apps that reject accessibility queries.
- Replacing text must stay safe: read and compare, select, compare again, then type.

Before opening a pull request:

```bash
swift run -c release Check --logic
./build.sh
Nachsatz.app/Contents/MacOS/Nachsatz --selftest out.png
```

If you change prompts or filters, include `Compare` numbers from before and after. Do not tune on `data/proof-2.json`.
