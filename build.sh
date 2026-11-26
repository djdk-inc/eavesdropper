#!/bin/bash
# Build, test and install Eavesdropper.app. Same commands in every djdk-inc Mac app:
#   ./build.sh test      # logic checks (DetectorChecks)
#   ./build.sh           # hermetic build → dist/Eavesdropper.app
#   ./build.sh install   # test + build + verify, quit the running app, replace /Applications/Eavesdropper.app, launch
# Signed with the stable "DJDK Local Code Signing" identity (created on first build), so macOS
# privacy grants survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
name=Eavesdropper
bundle_id=com.djdk.eavesdropper
export APP="dist/$name.app"

# Stable signing identity: same certificate every build → same designated requirement → grants stick.
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-DJDK Local Code Signing}"
ensure_identity() {
    local kc="$HOME/Library/Keychains/login.keychain-db"
    if ! security find-certificate -c "$CODESIGN_IDENTITY" "$kc" >/dev/null 2>&1; then
        local work pass; work="$(mktemp -d)"; pass="$(openssl rand -hex 16)"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CODESIGN_IDENTITY" \
            -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
            -addext "basicConstraints=critical,CA:false" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
        openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$CODESIGN_IDENTITY" \
            -passout "pass:$pass" -out "$work/id.p12"
        security import "$work/id.p12" -k "$kc" -P "$pass" -T /usr/bin/codesign >/dev/null
        rm -rf "$work"
        echo "created signing identity: $CODESIGN_IDENTITY"
    fi
    if ! security find-identity -v -p codesigning "$kc" | grep -q "\"$CODESIGN_IDENTITY\""; then
        echo "trusting $CODESIGN_IDENTITY for code signing (macOS asks for your password once)"
        local pem; pem="$(mktemp)"; security find-certificate -c "$CODESIGN_IDENTITY" -p "$kc" > "$pem"
        security add-trusted-cert -r trustRoot -p codeSign -k "$kc" "$pem"; rm -f "$pem"
    fi
}

run_tests() {
    swift build --build-system native --scratch-path .build --product DetectorChecks --disable-sandbox >/dev/null
    .build/debug/DetectorChecks | tail -1
}

build() {
    ensure_identity
    mkdir -p dist
    ./build-app.sh
}

install_app() {
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    while pgrep -xq "$name"; do sleep 0.2; done
    rm -rf "/Applications/$name.app"
    ditto "$APP" "/Applications/$name.app"
    open "/Applications/$name.app"
    echo "installed /Applications/$name.app"
}

case "${1:-build}" in
    test) run_tests ;;
    build) build ;;
    install) run_tests; build; ./verify.sh; install_app ;;
    *) echo "usage: ./build.sh [test|build|install]" >&2; exit 2 ;;
esac
