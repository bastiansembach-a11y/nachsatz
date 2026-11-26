# Nachsatz

[English](README.md)

Textvervollständigung für macOS, in (fast) jeder App. Läuft vollständig auf deinem Mac.

Nachsatz liest das Textfeld, in dem du schreibst, und schlägt in Grau direkt an der Schreibmarke vor, wie es weitergehen könnte. Tab übernimmt das nächste Wort. Es ergänzt auch mitten im Satz, unterstreicht Tipp- und Grammatikfehler, die du mit einem Klick korrigierst, kann sich deine Wendungen einige Tage merken und auf Wunsch ab und zu den sichtbaren Text auf dem Bildschirm als Kontext lesen. Am besten klappt es auf Deutsch und Englisch.

**Keine Cloud, kein Konto, keine Telemetrie.** Das Sprachmodell (Gemma 4 E2B) läuft lokal über llama.cpp.

> Frühe Fassung. In den genannten Apps läuft sie gut, andere sind ungetestet.

## Voraussetzungen

Mac mit Apple-Chip (16 GB empfohlen), macOS 26 oder neuer, Xcode Command Line Tools (`xcode-select --install`), rund 3,5 GB Platz.

## Installieren

```bash
git clone https://github.com/bastiansembach-a11y/nachsatz.git
cd nachsatz
./scripts/setup.sh
./build.sh
open Nachsatz.app
```

`setup.sh` fragt vor jedem Schritt und prüft die Prüfsumme des Modells. Fertige, von Apple beglaubigte Downloads gibt es noch nicht.

Danach unter **Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen** freigeben (macOS 27: „Gerätesteuerung und Datenzugriff“). Fehlt Nachsatz in der Liste, zieh das Symbol aus dem Nachsatz-Fenster hinein.

**Optional, Bildschirm als Kontext:** unter Vorschläge einschalten und Nachsatz unter **Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme** erlauben. Beim Schreiben liest Nachsatz dann höchstens alle 45 Sekunden den sichtbaren Text dieses Bildschirms (auf dem Mac, mit Apples Texterkennung), damit Vorschläge zur Mail oder zum Chat daneben passen. macOS fragt ab und zu erneut, ob Nachsatz den Bildschirm weiter aufnehmen darf.

**Nach einem Neubau** vergisst macOS die Freigaben, weil die App nur ad hoc signiert ist. Entferne den alten Eintrag und füge ihn neu hinzu, oder signiere mit deinem eigenen Zertifikat: `SIGN_ID="Apple Development: …" ./build.sh`.

## Tasten

| Taste | Wirkung |
| --- | --- |
| Tab | nächstes Wort übernehmen |
| Umschalt-Tab | ganzen Vorschlag übernehmen (umstellbar) |
| Esc | Vorschlag ausblenden |
| Klick auf Rot | Tippfehler korrigieren |
| Klick auf Blau | Grammatik und Kommas im Satz korrigieren |
| ⌥-Klick | künftig ignorieren |

## Datenschutz

Nachsatz braucht die Bedienungshilfen und kann damit Textfelder und Tastendrücke lesen. Was genau gelesen, behalten und protokolliert wird, steht in [PRIVACY.md](PRIVACY.md). Bitte vorher lesen.

Alles Weitere (Messwerte, Apps, Aufbau, Entwicklung) steht in der [englischen README](README.md).

## Lizenz

[MIT](LICENSE). Modell und llama.cpp sind eigene Projekte, siehe [THIRD_PARTY.md](THIRD_PARTY.md).
