#!/usr/bin/env bash
# Run the real init CLI with isolated filesystems; requires Go and Docker.
set -euo pipefail

cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/cnivpc-init-test.XXXXXX")
trap 'rm -f "$test_dir/cnivpc-init"; rmdir "$test_dir"' EXIT
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$test_dir/cnivpc-init" ./cmd/cnivpc-init

docker run --rm -i --network none --platform linux/amd64 \
  --tmpfs /app:exec --tmpfs /opt/cni:exec \
  --mount "type=bind,src=$test_dir/cnivpc-init,dst=/usr/local/bin/cnivpc-init,readonly" \
  --entrypoint /bin/sh "${CNI_INIT_TEST_IMAGE:-alpine:latest}" -s <<'EOF'
set -eu
mkdir -p /opt/cni/bin
source=/app/cnivpc
target=/opt/cni/bin/cnivpc

write_version() {
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$1"
  chmod 751 "$1"
}
digest() { sha256sum "$1" | cut -d ' ' -f 1; }
backup_count() { find /opt/cni/bin -name 'cnivpc.bak.*' | wc -l; }
run_init() { CNI_INIT_OVERWRITE="$1" /usr/local/bin/cnivpc-init; }
expect_failure() {
  if run_init true >/tmp/init.log 2>&1; then
    echo 'FAIL: expected init to reject an unusable backup' >&2
    exit 1
  fi
  cat /tmp/init.log
  test "$(digest "$target")" = "$old_digest"
}

write_version "$source" '2.0.0-alpha.5'
run_init false
cmp "$source" "$target"
test "$(backup_count)" = 0
echo 'PASS: first install needs no backup'

run_init true
test "$(backup_count)" = 0
echo 'PASS: same version is skipped without a backup'

write_version "$target" '2.0.2'
old_digest=$(digest "$target")
run_init false
test "$(digest "$target")" = "$old_digest"
test "$(backup_count)" = 0
echo 'PASS: overwrite=false preserves the existing binary'

run_init true
backup="$target.bak.$old_digest"
test "$(digest "$backup")" = "$old_digest"
test "$(stat -c %a "$backup")" = 751
cmp "$source" "$target"
test "$(backup_count)" = 1
echo 'PASS: replacement preserves old contents and executable permissions'

backup_inode=$(stat -c %i "$backup")
cp "$backup" "$target"
run_init true
test "$(backup_count)" = 1
test "$(stat -c %i "$backup")" = "$backup_inode"
test "$(digest "$backup")" = "$old_digest"
cmp "$source" "$target"
echo 'PASS: an identical old binary reuses its verified backup'

write_version "$target" '2.0.3'
old_digest=$(digest "$target")
run_init true
test "$(digest "$target.bak.$old_digest")" = "$old_digest"
test "$(backup_count)" = 2
test "$(stat -c %i "$backup")" = "$backup_inode"
echo 'PASS: a different old binary gets a separate backup'

cp "$target.bak.$old_digest" "$target"
printf 'corrupt backup\n' > "$target.bak.$old_digest"
expect_failure
grep -q 'checksum mismatch' /tmp/init.log
test "$(cat "$target.bak.$old_digest")" = 'corrupt backup'
echo 'PASS: a corrupt backup blocks replacement and is not overwritten'

write_version "$target" '2.0.4'
old_digest=$(digest "$target")
ln -s "$target" "$target.bak.$old_digest"
expect_failure
grep -q 'not a regular file' /tmp/init.log
echo 'PASS: a symlink cannot masquerade as a reusable backup'

write_version "$target" '2.0.5'
old_digest=$(digest "$target")
mkdir "$target.bak.$old_digest"
expect_failure
echo 'PASS: an obstructed backup path leaves the installed binary unchanged'

# New version can be read, but neither parent directory nor backup can be written.
write_version "$target" '2.0.6'
old_digest=$(digest "$target")
rm -f "$target.tmp"
chmod 555 /opt/cni/bin
if su -s /bin/sh nobody -c 'CNI_INIT_OVERWRITE=true /usr/local/bin/cnivpc-init' >/tmp/init.log 2>&1; then
  echo 'FAIL: expected write permission failure' >&2
  exit 1
fi
test "$(digest "$target")" = "$old_digest"
test ! -e "$target.bak.$old_digest"
echo 'PASS: write failure leaves the installed binary unchanged'
EOF
