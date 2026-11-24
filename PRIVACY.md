# Privacy

Nachsatz has access to what you type. This page says what it does with it.

## What it reads

- The focused text field: up to about 1200 characters before and 200 after the caret (up to 4000 around it for spell checking), through the macOS Accessibility API.
- Key presses, to notice typing and to intercept Tab and Esc **only while a suggestion is visible**.
- Mouse clicks and scrolling, to hide suggestions. A click is intercepted **only on an underlined mistake**.
- In apps that do not expose their text field it uses only the keys typed since the last click, kept in memory. You can turn this off ("Auch ohne lesbares Textfeld").

It ignores password fields, search fields, everything typed while macOS reports secure input, and excluded apps.

## What leaves your Mac

Nothing. The model server listens on `127.0.0.1` only, on a random port with a random key, and is started with `--offline`. Nachsatz makes no other connections. `scripts/setup.sh` downloads the model once, if you agree.

## What it keeps

- **Memory** (can be turned off, globally or per app): text you typed yourself, for 1 to 14 days (default 5), encrypted with AES-GCM in `~/Library/Application Support/Nachsatz/memory.bin`. The key is in your login keychain. A filter drops sentences with things that look like passwords, IBANs, long numbers, keys or links. **The filter does not catch everything.** Text typed in apps without a readable field is never stored.
- **Settings and counters:** `~/Library/Preferences/local.nachsatz.settings.plist`. Counters are numbers only.

## What it logs

App identifier, field role, text lengths, timings and outcome, in the macOS log (subsystem `local.nachsatz.read`). Never text. Other programs on your Mac can trigger one diagnostic line through a distributed notification. It contains roles and lengths only.

## Known limits

- Private browser windows cannot be recognized.
- A field that looks like normal text but holds a secret is treated as normal text. Exclude such apps.
- Nachsatz is only as trustworthy as the copy you run. Build it yourself or check the signature.

## Removing everything

Quit Nachsatz, then delete the app, `~/Library/Application Support/Nachsatz`, the settings file above, the keychain item "Nachsatz Gedächtnis" and the Accessibility entry.
