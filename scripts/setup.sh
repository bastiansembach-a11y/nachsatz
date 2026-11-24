#!/bin/zsh
# Installs what Nachsatz needs: llama.cpp (Homebrew) and the Gemma model file. Asks before every download.
set -e
REPO=mradermacher/gemma-4-E2B-GGUF
REV=8ac9604b5142320322af3b5dc0ab411ddff89343
FILE=gemma-4-E2B.Q4_K_M.gguf
SHA=389c868898bffed97fd178646f88562cafecc6f60983a636bac53b131fd068a2
DIR="$HOME/Library/Application Support/Nachsatz/Models"

ask() { read -q "REPLY?$1 [y/N] " || { echo; echo "Skipped."; return 1; }; echo; }

[[ $(uname -m) == arm64 ]] || { echo "Nachsatz needs a Mac with Apple silicon."; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) || { echo "Nachsatz needs macOS 26 or newer."; exit 1; }

if [[ -x /opt/homebrew/bin/llama-server || -x /usr/local/bin/llama-server ]]; then
  echo "llama.cpp: found"
elif (( $+commands[brew] )); then
  ask "Install llama.cpp with Homebrew?" && brew install llama.cpp
else
  echo "llama.cpp is missing and Homebrew was not found. See https://github.com/ggml-org/llama.cpp"; exit 1
fi

check() { [[ $(shasum -a 256 "$1" | cut -d' ' -f1) == $SHA ]]; }
if [[ -f "$DIR/$FILE" ]]; then
  echo "Model: found, checking …"
  check "$DIR/$FILE" && echo "Model: checksum ok" || { echo "Model: checksum does NOT match. Please delete $DIR/$FILE and run this again."; exit 1; }
else
  echo "Model: $FILE (3.4 GB) from huggingface.co/$REPO"
  ask "Download it now?" || exit 0
  mkdir -p "$DIR"
  curl -fL -C - -o "$DIR/$FILE.part" "https://huggingface.co/$REPO/resolve/$REV/$FILE"
  check "$DIR/$FILE.part" || { echo "Checksum does NOT match. The partial file stays at $DIR/$FILE.part"; exit 1; }
  mv "$DIR/$FILE.part" "$DIR/$FILE"
  echo "Model: installed"
fi
echo "Done. Now run ./build.sh and open Nachsatz.app"
