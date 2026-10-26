#!/bin/zsh
# Creates, once, a self-signed code-signing identity "Win7Mac Local Signing" in the login keychain, so
# `make shell` signs Win7Shell.app with a stable certificate and the Accessibility and Screen Recording
# grants keep matching after each rebuild. Uses only security(1) and openssl(1) from the base system.
#
# No sudo, no System keychain, no trust settings: codesign signs with an untrusted self-signed identity
# (find-identity lists it with CSSMERR_TP_NOT_TRUSTED, and not under "valid identities only"), and TCC
# matches the app by its designated requirement (identifier + leaf certificate hash), which does not
# depend on trust.
#
# No application is put on the key's access list, under any environment, so every signing with it asks
# for the keychain: answer "Allow", not "Always Allow". The import also requests a non-exportable key
# (security import -x), which macOS may not enforce for PKCS#12 imports.
#
# W7_KEYCHAIN overrides the keychain (the tests point it at a temporary keychain). Idempotent: if the
# identity is already there it is printed and the script exits 0.
set -euo pipefail

name="Win7Mac Local Signing"

unquote() { sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }

keychain="${W7_KEYCHAIN:-}"
if [ -z "$keychain" ]; then
    keychain="$(security login-keychain 2>/dev/null | unquote || true)"
    [ -n "$keychain" ] || keychain="$HOME/Library/Keychains/login.keychain-db"
fi

# Resolve symlinks and .. physically (:P, like realpath), check that path, and then use exactly that
# path, so a symlinked or ..-laden W7_KEYCHAIN cannot reach a keychain other than the one checked.
resolved="${keychain:P}"
case "$resolved" in
    /Library/Keychains/*|/System/*|/private/var/db/*|*/System.keychain|*/System.keychain-db)
        echo "make-signing-identity: refusing to use the System keychain ($keychain -> $resolved)" >&2
        exit 1 ;;
esac
keychain="$resolved"

existing="$(security find-identity -p codesigning "$keychain" 2>/dev/null | grep -F "\"$name\"" || true)"
if [ -n "$existing" ]; then
    echo "Signing identity already present in $keychain:"
    echo "$existing"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
umask 077

cat >"$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$tmp/req.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# A throwaway password protects the bundle only for the hand-off to security import. The PBE and MAC
# algorithms are spelled out because security import cannot read newer openssl defaults.
pass="w7-$$-$RANDOM"
openssl pkcs12 -export -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$pass" -out "$tmp/identity.p12"
# Never -T: no application is on the key's access list, so every use of the key (each `make shell`) asks
# for the keychain. Answer "Allow", not "Always Allow" (README, Stable signing). -x requests a
# non-exportable key; macOS may not enforce that for PKCS#12 imports.
security import "$tmp/identity.p12" -k "$keychain" -f pkcs12 -P "$pass" -x >/dev/null

created="$(security find-identity -p codesigning "$keychain" 2>/dev/null | grep -F "\"$name\"" || true)"
if [ -z "$created" ]; then
    echo "make-signing-identity: imported, but find-identity does not list \"$name\" in $keychain" >&2
    exit 1
fi
echo "Created signing identity in $keychain:"
echo "$created"
