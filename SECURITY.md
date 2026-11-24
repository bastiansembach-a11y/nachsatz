# Security

Nachsatz reads text fields and key presses, so security reports matter.

Please report vulnerabilities **privately** through GitHub: *Security > Report a vulnerability* in this repository. Do not open a public issue for them, and never attach real personal text, `memory.bin` or keychain data.

Interesting areas: the memory filter (`NoteFilter`), secure-input and password-field handling, the local server (key, port, lifetime), click-to-fix replacing text, and the key tap.

Not in scope: apps that reject accessibility queries. Nachsatz does not try to get around that.
