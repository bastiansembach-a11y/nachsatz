# Changelog

## Unreleased

- Prompt header from app and window title, e.g. "Betreff: …" above an email or "Chatnachricht" in a chat app. First word right 57.8 % instead of 52.2 % (right at 43 places that were wrong before, wrong at 8 that were right), 27 % more keystrokes saved. The window title can be switched off ("Fenstertitel nutzen"), then only the kind of app is used. `Compare llama rahmen` measures it.
- Fix: the Mac could stop reacting to clicks while the Accessibility permission for Nachsatz was changed in System Settings. Nachsatz now pauses its key and mouse tap while System Settings is in front, and after macOS switches the tap off because Nachsatz was too slow, it waits before switching it back on instead of doing so at once.
- Caution setting: suggestions are hidden if the first word is unlikely (with a lower bar inside a started word) and shortened where the whole suggestion gets unlikely. Levels set from measurements; on average fewer than one word per suggestion was right, so most of the cut text was gray noise. Uses the token probabilities from llama-server, the diagnosis says when a suggestion was held back.
- `Compare llama treffer`: larger hit-rate test set with results for every caution threshold, per kind of text and as a calibration table

## 0.1.0

First public version.

- Inline completion in German and English with Gemma 4 E2B, streamed word by word
- Filling gaps in the middle of a sentence
- One-click spelling and grammar fixes
- Encrypted memory and personal style in four levels
- Support for native, WebKit, Chromium and Electron text fields
- Main window with Liquid Glass, word counter in the menu bar
