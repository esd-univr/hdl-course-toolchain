#!/usr/bin/env bash
# Integration tests for prepare-release.sh / publish-release.sh / release_lib.sh.
# Never touches the real origin or a real registry: docker and gh are PATH stubs
# that log their arguments and answer from files in a scratch dir; origin is a
# local bare repo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }
neq0()  { [ "$2" != "0" ] && ok || bad "$1 — expected non-zero exit" "$2"; }

cd "$ROOT" || exit 1

# shellcheck source=scripts/release_lib.sh
. scripts/release_lib.sh

echo "== release_lib.sh tests =="

# --- release_inputs_fingerprint ------------------------------------------
fp1="$(release_inputs_fingerprint)"
eq "release_inputs_fingerprint is 64 hex" "$(printf '%s' "$fp1" | wc -c | tr -d ' ')" "64"
case "$fp1" in
    *[!0-9a-f]*) bad "release_inputs_fingerprint is lowercase hex" "$fp1" ;;
    *) ok ;;
esac

# mutating a release input changes the fingerprint
tmp="$(mktemp)"; cp VERSION "$tmp"
trap 'cp "$tmp" "$ROOT/VERSION"; rm -f "$tmp"' EXIT
printf 'x\n' >> VERSION
fp2="$(release_inputs_fingerprint)"
[ "$fp1" != "$fp2" ] && ok || bad "fingerprint should change when VERSION changes"
cp "$tmp" VERSION

# restored input restores the fingerprint
eq "fingerprint is stable once VERSION is restored" "$(release_inputs_fingerprint)" "$fp1"

# --- build_inputs_fingerprint (delegates to artifact-status.sh) ---------
bfp="$(build_inputs_fingerprint)"
eq "build_inputs_fingerprint is 64 hex" "$(printf '%s' "$bfp" | wc -c | tr -d ' ')" "64"
eq "build_inputs_fingerprint matches artifact-status.sh fingerprint docker" \
   "$bfp" "$(scripts/artifact-status.sh fingerprint docker)"

# --- ghcr_ref / constants ---------------------------------------------
eq "ghcr_ref" "$(ghcr_ref v1.3.1)" "ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1"
eq "REPO constant" "$REPO" "esd-univr/hdl-course-toolchain"
eq "IMAGE_BASE constant" "$IMAGE_BASE" "ghcr.io/esd-univr/hdl-course-toolchain"
eq "PLATFORM_DEFAULT constant" "$PLATFORM_DEFAULT" "linux/amd64"

echo
echo "== prepare-release.sh preconditions =="
setup_repo() {
  WORK="$(mktemp -d)"; export WORK
  git init -q -b main "$WORK/up.git" --bare
  git clone -q "$WORK/up.git" "$WORK/repo" 2>/dev/null
  cd "$WORK/repo" || exit 1
  git config user.email t@t; git config user.name t
  mkdir -p scripts bin
  cp "$ROOT/scripts/release_lib.sh" "$ROOT/scripts/prepare-release.sh" scripts/
  cp "$ROOT/scripts/artifact-status.sh" scripts/ 2>/dev/null || true
  printf '1.2.0\n' > VERSION
  printf 'LAUNCHER_VERSION="1.2.0"\n' > bin/hdl-toolchain
  printf 'VERSION="v0.0.0-dev"\nSHA256="x"\n' > install.sh
  printf 'VERSION="v0.0.0-dev"\n' > uninstall.sh
  # stub the digest sync + make the suites prepare-release runs no-ops, so a run
  # that clears preconditions can proceed to pin + commit without a real toolchain
  cat > scripts/sync-installer-digest.sh <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "--check" ] && exit 0
sed -i 's/^SHA256=.*/SHA256="deadbeef"/' install.sh
S
  chmod +x scripts/sync-installer-digest.sh
  printf 'check:\n\t@true\ntest:\n\t@true\n' > Makefile
  git add -A; git commit -qm init; git push -q origin main
  mkdir "$WORK/stub"
  cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
  cat > "$WORK/stub/docker" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"imagetools inspect"*) exit 1 ;;
  *"manifest inspect"*) exit 1 ;;
  *) exit 0 ;;
esac
S
  chmod +x "$WORK/stub"/*
  export PATH="$WORK/stub:$PATH"
}
teardown_repo() { cd "$ROOT" || exit 1; rm -rf "$WORK"; }

setup_repo
out="$(bash scripts/prepare-release.sh not-a-version 2>&1)"; neq0 "bad version rejected" "$?"
has "bad version message" "$out" "vX.Y.Z"
git switch -qc side
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "not on main rejected" "$?"
has "not-on-main message" "$out" "main"
git switch -qm main >/dev/null 2>&1 || git switch -q main
echo dirt > dirty; git add dirty
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "dirty tree rejected" "$?"
git reset -q --hard >/dev/null
# ahead of origin/main
git commit -q --allow-empty -m ahead
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "ahead of origin rejected" "$?"
has "ahead message" "$out" "origin/main"
git reset -q --hard origin/main
# clean main at origin/main, dev sentinel, version unused -> preconditions pass
# (the run then proceeds through pin + commit; reset back to a clean main after)
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "preconditions pass on clean main" "$?" "0"
has "preconditions-ok message" "$out" "preconditions OK"
git reset -q --hard origin/main
# a local tag for the target version aborts version_unused
git tag v1.3.1
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "existing local tag rejected" "$?"
has "local tag message" "$out" "already exists locally"
git tag -d v1.3.1 >/dev/null
# dev sentinel gone from origin (a release half-pinned) aborts, even with
# HEAD exactly on origin/main
printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
git commit -qam "wip pin"; git push -q origin main
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "missing dev sentinel rejected" "$?"
has "sentinel message" "$out" "sentinel"
git reset -q --hard HEAD~1; git push -qf origin main
# idempotent resume: HEAD is the matching release commit, parent == origin/main
printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
printf 'VERSION="v1.3.1"\n' > uninstall.sh
printf 'LAUNCHER_VERSION="1.3.1"\n' > bin/hdl-toolchain
printf '1.3.1\n' > VERSION
git commit -qam "release: v1.3.1"
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "resume exits 0" "$?" "0"
has "resume message" "$out" "already prepared at HEAD"
# ... but resume must NOT fire when the version is already claimed elsewhere
git tag v1.3.1
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; rc=$?
neq0 "resume blocked when tag exists" "$rc"
case "$out" in
  *"already prepared"*) bad "resume must not claim already-prepared when tag exists" "$out" ;;
  *) ok ;;
esac
git tag -d v1.3.1 >/dev/null
git reset -q --hard origin/main
teardown_repo

echo
echo "== prepare-release.sh pins and commits =="
setup_repo   # ships a sync-installer-digest.sh stub + no-op check/test Makefile
BASE_SHA="$(git rev-parse origin/main)"
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "prepare exits 0" "$?" "0"
eq "VERSION pinned bare" "$(cat VERSION)" "1.3.1"
has "launcher pinned" "$(cat bin/hdl-toolchain)" 'LAUNCHER_VERSION="1.3.1"'
has "installer pinned" "$(cat install.sh)" 'VERSION="v1.3.1"'
has "uninstaller pinned" "$(cat uninstall.sh)" 'VERSION="v1.3.1"'
has "installer digest synced" "$(cat install.sh)" 'SHA256="deadbeef"'
eq "commit subject" "$(git log -1 --format=%s)" "release: v1.3.1"
eq "parent is origin/main" "$(git rev-parse HEAD^)" "$BASE_SHA"
eq "nothing pushed" "$(git rev-parse origin/main)" "$BASE_SHA"
eq "no tag created" "$(git tag | wc -l | tr -d ' ')" "0"
eq "release commit stages exactly four files" \
   "$(git show --name-only --format= HEAD | grep -c .)" "4"
has "stages VERSION"       "$(git show --name-only --format= HEAD)" "VERSION"
has "stages launcher"      "$(git show --name-only --format= HEAD)" "bin/hdl-toolchain"
has "stages install.sh"    "$(git show --name-only --format= HEAD)" "install.sh"
has "stages uninstall.sh"  "$(git show --name-only --format= HEAD)" "uninstall.sh"
has "next-steps block: qualify" "$out" "make qualify"
has "next-steps block: publish" "$out" "make publish VERSION=v1.3.1"
# idempotent re-run: HEAD is the matching release commit
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "re-run exits 0" "$?" "0"
has "re-run says already prepared" "$out" "already prepared"
eq "re-run adds no commit" "$(git rev-parse HEAD^)" "$BASE_SHA"
teardown_repo

echo
echo "== publish-release.sh validation gate =="
setup_pub() {   # scratch repo with a committed release + a fake qualified image
  setup_repo
  # publish-release.sh + qualification.py are not part of setup_repo's copy set
  cp "$ROOT/scripts/publish-release.sh" "$ROOT/scripts/qualification.py" scripts/
  printf '.out/\n' > .gitignore
  printf 'check:\n\t@true\ntest:\n\t@true\n' > Makefile
  git add -A; git commit -qm makefile; git push -q origin main
  # pin + commit like prepare would
  printf '1.3.1\n' > VERSION
  printf 'LAUNCHER_VERSION="1.3.1"\n' > bin/hdl-toolchain
  printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
  printf 'VERSION="v1.3.1"\n' > uninstall.sh
  mkdir -p .out doctor container
  printf 'a\n' > versions.yml; printf 'b\n' > Containerfile; printf 'c\n' > requirements.txt
  git add -A; git commit -qm "release: v1.3.1"
  HEAD_SHA="$(git rev-parse HEAD)"
  . scripts/release_lib.sh
  IMG_ID="sha256:$(printf '%s' fixed | sha256sum | cut -c1-64)"
  DIGEST="sha256:$(printf '%s' pushdigest | sha256sum | cut -c1-64)"; export DIGEST
  # docker stub: logs args, answers `image inspect --format {{.Id}} <ref>` and
  # `info`, and models the registry state for the versioned tag — the
  # `:vX.Y.Z` manifest is ABSENT until a `docker push` drops the marker file,
  # PRESENT (with $DIGEST) afterwards.
  cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
pushed="$WORK/pushed"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) [ -f "\$pushed" ] && { echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  "push "*) touch "\$pushed"; exit 0 ;;
  "tag "*) exit 0 ;;
  "info") exit 0 ;;
  *"image inspect"*) exit 1 ;;
  *) exit 0 ;;
esac
S
  chmod +x "$WORK/stub/docker"
  python3 scripts/qualification.py record --out .out/qualification.json \
    --version v1.3.1 --source-commit "$HEAD_SHA" --tree-clean 1 \
    --build-inputs-sha256 "$(build_inputs_fingerprint)" \
    --release-inputs-sha256 "$(release_inputs_fingerprint)" \
    --docker-image-ref hdl-course-toolchain:latest --docker-image-id "$IMG_ID" \
    --sif-path .out/x.sif --sif-sha256 deadbeef --platform linux/amd64 --arch x86_64 \
    --doctor-docker pass --doctor-apptainer pass
}

# 8a: clean state validates OK (stops before any push once Task 8 is all there is)
setup_pub
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "8a clean state exits 0" "$?" "0"
has "8a qualification record matches" "$out" "qualification: record matches"
has "8a validation OK line" "$out" "validation OK"
teardown_repo

# 8b: arg != record
setup_pub
out="$(bash scripts/publish-release.sh v9.9.9 2>&1)"; neq0 "8b version arg mismatch rejected" "$?"
has "8b names the version mismatch" "$out" "version mismatch"
teardown_repo

# 8c: HEAD moved
setup_pub
git commit -q --allow-empty -m drift
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8c HEAD moved rejected" "$?"
has "8c HEAD moved message" "$out" "source_commit mismatch"
teardown_repo

# 8d: build inputs changed
setup_pub
printf 'CHANGED\n' >> versions.yml
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8d build inputs changed rejected" "$?"
has "8d names the build-inputs mismatch" "$out" "build_inputs_sha256 mismatch"
teardown_repo

# 8e: release inputs changed
setup_pub
printf 'x\n' >> uninstall.sh
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8e release inputs changed rejected" "$?"
has "8e names the release-inputs mismatch" "$out" "release_inputs_sha256 mismatch"
teardown_repo

# 8f: wrong local image id
setup_pub
cat > "$WORK/stub/docker" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "sha256:0000"; exit 0 ;;
  "info") exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8f wrong image id rejected" "$?"
has "8f image id message" "$out" "docker_image_id mismatch"
teardown_repo

# 8g: no record
setup_pub
rm -f .out/qualification.json
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8g missing record rejected" "$?"
has "8g missing record message" "$out" "make qualify"
teardown_repo

# 8h: gh not authenticated -> require_tooling aborts
setup_pub
cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) echo "not logged in" >&2; exit 1 ;;
  *"release view"*) exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "8h gh unauthenticated rejected" "$?"
has "8h gh auth message" "$out" "gh is not authenticated"
teardown_repo

echo
echo "== publish: versioned image =="

# 9a: fresh push — :v1.3.1 absent, pushed, digest read back into the ledger
setup_pub
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "9a fresh push exits 0" "$?" "0"
grep -q "push ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1" "$WORK/docker.log" \
  && ok || bad "9a versioned push happened" "$(cat "$WORK/docker.log")"
has "9a announces the publish" "$out" "published"
eq "9a ledger records the live digest" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["image_digest"])')" "$DIGEST"
eq "9a ledger version" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["version"])')" "v1.3.1"
eq "9a ledger source_commit" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["source_commit"])')" "$(git rev-parse HEAD)"
eq "9a :latest untouched" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["latest_moved"])')" "False"
teardown_repo

# 9b: resume — :v1.3.1 already present with the SAME image id -> continue, no re-push
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect --format {{.Id}} ghcr"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "pull "*) exit 0 ;;
  "tag "*) exit 0 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "9b resume exits 0" "$?" "0"
if grep -q "^push ghcr.*:v1.3.1" "$WORK/docker.log"; then bad "9b should NOT re-push"; else ok; fi
has "9b resume message" "$out" "already published"
eq "9b ledger adopts the live digest" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["image_digest"])')" "$DIGEST"
teardown_repo

# 9c: conflict — :v1.3.1 present with a DIFFERENT image id -> abort, immutable
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect --format {{.Id}} ghcr"*) echo "sha256:different"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "pull "*) exit 0 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "9c immutable conflict aborts" "$?"
has "9c immutable message" "$out" "immutable"
if grep -q "^push ghcr.*:v1.3.1" "$WORK/docker.log"; then bad "9c must not push over a conflict"; else ok; fi
teardown_repo

echo
echo "release_lib: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
