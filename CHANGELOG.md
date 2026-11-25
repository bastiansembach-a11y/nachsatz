# Changelog

## Unreleased

- Caution setting: suggestions are shortened where the model gets unsure, and hidden if even the first word is unlikely. Uses the token probabilities from llama-server, the diagnosis says when a suggestion was held back.
- `Compare llama treffer`: larger hit-rate test set with results for every caution threshold, per kind of text and as a calibration table

## 0.1.0

First public version.

- Inline completion in German and English with Gemma 4 E2B, streamed word by word
- Filling gaps in the middle of a sentence
- One-click spelling and grammar fixes
- Encrypted memory and personal style in four levels
- Support for native, WebKit, Chromium and Electron text fields
- Main window with Liquid Glass, word counter in the menu bar
