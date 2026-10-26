#!/bin/zsh
# Tests the Makefile's codesign identity selection (with a stubbed security(1) first on PATH) and
# scripts/make-signing-identity.sh against a temporary keychain. The login and System keychains are
# never written: every run of the script here gets W7_KEYCHAIN or a stubbed security.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
ptmp="${tmp:P}"   # the script resolves keychain paths physically (/var -> /private/var)
keychain="$tmp/w7-test.keychain"
tmpkc="$tmp/w7-codesign-test.keychain"
cleanup() {
    for k in "$keychain" "$tmpkc"; do
        [ -e "$k" ] && security delete-keychain "$k" 2>/dev/null
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

name="Win7Mac Local Signing"
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$tmp/bin" "$tmp/home"
export W7_STUB_LOG="$tmp/stub.log"
: >"$W7_STUB_LOG"

# --- Makefile identity selection ---------------------------------------------------------------
# The stub answers find-identity with $W7_STUB_IDENTITIES (exit $W7_STUB_EXIT, default 0). With
# W7_STUB_STATE set, it lists nothing until an import has created that file.
cat >"$tmp/bin/security" <<'S'
#!/bin/sh
echo "security $*" >>"$W7_STUB_LOG"
case "$1" in
  login-keychain) echo "    \"${W7_STUB_LOGIN_KEYCHAIN:-/nonexistent/login.keychain-db}\"" ;;
  find-identity)
    if [ -z "${W7_STUB_STATE:-}" ] || [ -e "$W7_STUB_STATE" ]; then printf '%b' "${W7_STUB_IDENTITIES:-}"; fi ;;
  list-keychains) for k in ${W7_STUB_SEARCH_LIST:-}; do echo "    \"$k\""; done ;;
  import) [ -n "${W7_STUB_STATE:-}" ] && : >"$W7_STUB_STATE" ;;
  *) echo "stub security: unexpected $*" >&2; exit 99 ;;
esac
exit "${W7_STUB_EXIT:-0}"
S
chmod +x "$tmp/bin/security"

# The recipes make would run, without running them (-n). The nested make is isolated from the make test
# that runs this script: no inherited MAKEFLAGS (-n, -k, variables) and no CODESIGN_IDENTITY from the caller.
run_make() { env -u CODESIGN_IDENTITY -u MAKEFLAGS PATH="$tmp/bin:$PATH" make -n -C "$root" "$@" 2>/dev/null; }
make_shell() { run_make shell "$@"; }

untrusted="\nPolicy: Code Signing\n  Matching identities\n  1) FFAFB232513B94517B1F29384E5485C87F6EF902 \"$name\" (CSSMERR_TP_NOT_TRUSTED)\n     1 identities found\n\n  Valid identities only\n     0 valid identities found\n"
other="\nPolicy: Code Signing\n  Matching identities\n  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"$name 2\"\n     1 identities found\n"
none="\nPolicy: Code Signing\n  Matching identities\n     0 identities found\n"

out="$(W7_STUB_IDENTITIES="$untrusted" make_shell)"
grep -qF "codesign -f --timestamp=none -s \"$name\" build/Win7Shell.app" <<<"$out" || fail "listed (untrusted) identity not used: $out"
grep -qF 'answer "Allow", not "Always Allow"' <<<"$out" || fail "keychain reminder not printed: $out"
grep -qF "Signing Win7Shell.app with: $name" <<<"$out" || fail "chosen identity not printed: $out"
grep -qF "security find-identity -p codesigning" "$W7_STUB_LOG" || fail "make did not ask find-identity"

out="$(W7_STUB_IDENTITIES="$none" make_shell)"
grep -qF 'codesign -f --timestamp=none -s "-" build/Win7Shell.app' <<<"$out" || fail "no identity: not ad-hoc: $out"
grep -qF 'Always Allow' <<<"$out" && fail "keychain reminder printed for ad-hoc signing: $out"
grep -qF 'Signing Win7Shell.app with: -' <<<"$out" || fail "ad-hoc choice not printed: $out"

out="$(W7_STUB_IDENTITIES="$other" make_shell)"
grep -qF 'codesign -f --timestamp=none -s "-" build/Win7Shell.app' <<<"$out" || fail "similarly named identity was used: $out"

out="$(W7_STUB_EXIT=1 make_shell)"
grep -qF 'codesign -f --timestamp=none -s "-" build/Win7Shell.app' <<<"$out" || fail "failing security: not ad-hoc: $out"

out="$(W7_STUB_IDENTITIES="$untrusted" make_shell CODESIGN_IDENTITY="My Cert")"
grep -qF 'codesign -f --timestamp=none -s "My Cert" build/Win7Shell.app' <<<"$out" || fail "command-line identity ignored: $out"

# A CODESIGN_IDENTITY or MAKEFLAGS inherited from the caller does not leak into run_make.
out="$(CODESIGN_IDENTITY="Leaked Cert" MAKEFLAGS="CODESIGN_IDENTITY=Leaked" W7_STUB_IDENTITIES="$none" make_shell)"
grep -qF 'codesign -f --timestamp=none -s "-" build/Win7Shell.app' <<<"$out" || fail "caller environment leaked into make: $out"

out="$(run_make signing-identity)"
grep -qF "scripts/make-signing-identity.sh" <<<"$out" || fail "make signing-identity does not run the script: $out"

# --- make-signing-identity.sh: System keychain refused before any security call ------------------
for k in /Library/Keychains/System.keychain /Library/Keychains/System.keychain-db; do
    : >"$W7_STUB_LOG"
    if HOME="$tmp/home" PATH="$tmp/bin:$PATH" W7_KEYCHAIN="$k" "$root/scripts/make-signing-identity.sh" >/dev/null 2>&1; then
        fail "System keychain accepted: $k"
    fi
    [ -s "$W7_STUB_LOG" ] && fail "security ran for the System keychain: $(cat "$W7_STUB_LOG")"
done

# --- make-signing-identity.sh: default keychain is the login keychain (stubbed, already present) --
: >"$W7_STUB_LOG"
out="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" W7_STUB_LOGIN_KEYCHAIN="$tmp/fake-login.keychain-db" \
       W7_STUB_IDENTITIES="$untrusted" "$root/scripts/make-signing-identity.sh" 2>&1)" || fail "existing identity: non-zero exit: $out"
grep -qF "security find-identity -p codesigning $ptmp/fake-login.keychain-db" "$W7_STUB_LOG" \
    || fail "default keychain is not the login keychain: $(cat "$W7_STUB_LOG")"
grep -q "security import" "$W7_STUB_LOG" && fail "existing identity was imported again"
grep -qF "\"$name\"" <<<"$out" || fail "existing identity not printed: $out"

# --- make-signing-identity.sh: the default path imports non-exportable, with no codesign ACL entry ---
# Without -T nothing is on the key's access list, so every codesign use of the key asks the user.
: >"$W7_STUB_LOG"
out="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" W7_STUB_LOGIN_KEYCHAIN="$tmp/fake-login.keychain-db" \
       W7_STUB_STATE="$tmp/imported" W7_STUB_IDENTITIES="$untrusted" "$root/scripts/make-signing-identity.sh" 2>&1)" \
    || fail "default create: non-zero exit: $out"
import_line="$(grep "^security import " "$W7_STUB_LOG")" || fail "default create: no import: $(cat "$W7_STUB_LOG")"
grep -qF -- "-k $ptmp/fake-login.keychain-db " <<<"$import_line" || fail "import not into the login keychain: $import_line"
grep -qF -- " -x" <<<"$import_line" || fail "key not imported non-exportable: $import_line"
grep -qF -- " -T " <<<"$import_line " && fail "import puts an application on the key's access list: $import_line"
rm -f "$tmp/imported"

# --- make-signing-identity.sh: W7_KEYCHAIN is resolved physically, checked, and used as resolved ------
# A plain symlink to /Library and a symlink followed by .. (the kernel follows the link before applying
# .., so a lexical check would see $tmp/Keychains/...) must both be refused as the System keychain.
ln -s /Library "$tmp/sys"
ln -s /Library/Keychains "$tmp/link"
for k in "$tmp/sys/Keychains/System.keychain" "$tmp/link/../Keychains/w7-probe.keychain-db"; do
    : >"$W7_STUB_LOG"
    if err="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" W7_KEYCHAIN="$k" W7_STUB_STATE="$tmp/imported" \
             "$root/scripts/make-signing-identity.sh" 2>&1 >/dev/null)"; then
        fail "symlinked System keychain accepted: $k"
    fi
    grep -qF "refusing to use the System keychain" <<<"$err" || fail "$k: refused for another reason: $err"
    [ -s "$W7_STUB_LOG" ] && fail "security ran for $k: $(cat "$W7_STUB_LOG")"
done
rm -f "$tmp/imported"

# The path the script checked is the path it hands to security: symlink + .. resolves physically.
mkdir -p "$tmp/home/Library/Keychains"
ln -s "$tmp/home/Library" "$tmp/homelib"
: >"$W7_STUB_LOG"
out="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" W7_KEYCHAIN="$tmp/homelib/../Library/Keychains/w7.keychain-db" \
       W7_STUB_IDENTITIES="$untrusted" "$root/scripts/make-signing-identity.sh" 2>&1)" || fail "symlinked keychain: non-zero exit: $out"
grep -qF "security find-identity -p codesigning $ptmp/home/Library/Keychains/w7.keychain-db" "$W7_STUB_LOG" \
    || fail "security did not get the resolved path: $(cat "$W7_STUB_LOG")"

# Runs "$@" but kills it after $1 seconds (exit 124), so a keychain prompt can never hang the test.
with_timeout() {
    local secs=$1 pid i=0
    shift
    "$@" &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
        if (( i++ >= secs * 10 )); then kill $pid 2>/dev/null; wait $pid 2>/dev/null; return 124; fi
        sleep 0.1
    done
    wait $pid
}

# --- make-signing-identity.sh against a temporary keychain ---------------------------------------
search_before="$(security list-keychains -d user)"
security create-keychain -p test "$keychain" || fail "cannot create the temporary keychain"
security unlock-keychain -p test "$keychain" || fail "cannot unlock the temporary keychain"

out="$(HOME="$tmp/home" W7_KEYCHAIN="$keychain" "$root/scripts/make-signing-identity.sh" 2>&1)" || fail "script failed: $out"
grep -qF "Created signing identity" <<<"$out" || fail "first run did not create: $out"
ids="$(security find-identity -p codesigning "$keychain")"
[ "$(echo "$ids" | grep -cF "\"$name\"")" -eq 1 ] || fail "identity not listed once: $ids"

out="$(HOME="$tmp/home" W7_KEYCHAIN="$keychain" "$root/scripts/make-signing-identity.sh" 2>&1)" || fail "second run failed: $out"
grep -qF "already present" <<<"$out" || fail "second run not idempotent: $out"
grep -qF "\"$name\"" <<<"$out" || fail "second run did not print the identity: $out"
ids="$(security find-identity -p codesigning "$keychain")"
[ "$(echo "$ids" | grep -cF "\"$name\"")" -eq 1 ] || fail "second run added another identity: $ids"

security delete-keychain "$keychain" || fail "cannot delete the temporary keychain"

# --- codesign accepts an untrusted self-signed code-signing leaf ----------------------------------
# The script never puts codesign on a key's access list, so signing with its key would prompt. This
# check therefore builds its own throwaway identity, with the same certificate extensions as the script,
# in its own temporary keychain, and only here adds codesign to the access list (-T) and sets the
# partition list with the test password. The watchdog guards against a prompt anyway.
tname="Win7Mac Test Signing"
security create-keychain -p test "$tmpkc" || fail "cannot create the codesign test keychain"
security unlock-keychain -p test "$tmpkc" || fail "cannot unlock the codesign test keychain"
cat >"$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $tname
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -config "$tmp/req.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null || fail "cannot create the test certificate"
openssl pkcs12 -export -name "$tname" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout pass:test -out "$tmp/test.p12" \
    || fail "cannot create the test identity"
security import "$tmp/test.p12" -k "$tmpkc" -f pkcs12 -P test -T /usr/bin/codesign >/dev/null \
    || fail "cannot import the test identity"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k test "$tmpkc" >/dev/null 2>&1 \
    || fail "cannot set the key partition list"
ids="$(security find-identity -p codesigning "$tmpkc")"
grep -qF "\"$tname\" (CSSMERR_TP_NOT_TRUSTED)" <<<"$ids" || fail "test identity not listed as untrusted: $ids"
printf 'int main(void){return 0;}\n' >"$tmp/m.c"
clang -o "$tmp/m" "$tmp/m.c" || fail "cannot build the test binary"
with_timeout 30 codesign -f --timestamp=none -s "$tname" --keychain "$tmpkc" "$tmp/m" >/dev/null 2>&1
cs=$?
[ $cs -eq 124 ] && fail "codesign did not finish within 30 s (keychain prompt? dismiss any keychain dialog)"
[ $cs -eq 0 ] || fail "codesign refused the identity (exit $cs)"
info="$(codesign -dvv "$tmp/m" 2>&1)"
grep -qF "Authority=$tname" <<<"$info" || fail "binary not signed by $tname: $info"
req="$(codesign -d -r- "$tmp/m" 2>&1)"
grep -q 'certificate leaf = H"' <<<"$req" || fail "designated requirement does not pin the leaf: $req"

security delete-keychain "$tmpkc" || fail "cannot delete the codesign test keychain"
[ "$(security list-keychains -d user)" = "$search_before" ] || fail "keychain search list changed"

echo "test_signing: all checks passed"
