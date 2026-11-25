#!/bin/bash
# Rebuilds the app twice from scratch and checks both builds are byte-identical.
set -euo pipefail
cd "$(dirname "$0")"
tree_hash() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | cut -d' ' -f1; }
for run in a b; do
    rm -rf .build-repro "Eavesdropper-$run.app"
    SCRATCH=.build-repro APP="Eavesdropper-$run.app" ./build-app.sh >/dev/null
done
a="$(tree_hash Eavesdropper-a.app)"; b="$(tree_hash Eavesdropper-b.app)"
if [ "$a" = "$b" ]; then
    echo "reproducible: $a"
    rm -rf Eavesdropper-a.app Eavesdropper-b.app .build-repro
else
    echo "NOT reproducible: $a vs $b" >&2
    diff <(cd Eavesdropper-a.app && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
         <(cd Eavesdropper-b.app && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) >&2 || true
    exit 1
fi
