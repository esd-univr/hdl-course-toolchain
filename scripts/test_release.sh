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
echo "== machinery wiring =="
make -n prepare VERSION=v1.3.1 >/dev/null 2>&1 && ok || bad "make prepare target exists"
make -n publish VERSION=v1.3.1 >/dev/null 2>&1 && ok || bad "make publish target exists"
rel_out="$(make release 2>&1 || true)"
has "make release points at new flow" "$rel_out" "make prepare"
test ! -e scripts/release.sh && ok || bad "scripts/release.sh removed"
grep -q 'scripts/prepare-release.sh' Makefile && ok || bad "Makefile calls prepare-release.sh"

echo
echo "== workflows are lightweight only =="
test ! -e .github/workflows/release.yml && ok || bad "release.yml deleted"
test -f .github/workflows/check.yml && ok || bad "check.yml (lightweight CI) is still present"
wf_bad='tags:|on: *(release|create)|make build|make fetch|make publish|ghcr\.io|docker push|build-push-action|prepare-release|publish-release'
if grep -rnE "$wf_bad" .github/workflows/ >/dev/null 2>&1; then
  bad "a workflow references heavyweight release steps" \
      "$(grep -rnE "$wf_bad" .github/workflows/)"
else ok; fi
grep -q 'test_release.sh' Makefile && ok || bad "make test runs test_release.sh"

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
echo "== prepare-release.sh aborts before committing when make test fails =="
setup_repo
printf 'check:\n\t@true\ntest:\n\t@false\n' > Makefile   # make test fails on the pinned tree
git add Makefile; git commit -qm "make test fails"; git push -q origin main
FAIL_BASE="$(git rev-parse origin/main)"
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; rc=$?
neq0 "prepare aborts when make test fails" "$rc"
eq "HEAD did not move (no release commit)" "$(git rev-parse HEAD)" "$FAIL_BASE"
case "$(git log -1 --format=%s)" in
  "release: v1.3.1") bad "a release commit must not exist after a failed make test" ;;
  *) ok ;;
esac
eq "still nothing pushed" "$(git rev-parse origin/main)" "$FAIL_BASE"
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
  # `info`, and models the registry state for BOTH published tags via two marker
  # files — `:vX.Y.Z` (`$WORK/pushed`) and `:latest` (`$WORK/lat`). Each
  # `imagetools inspect` arm returns $DIGEST only once the matching marker
  # exists; a `docker push` of that tag drops the marker.
  cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
pushed="$WORK/pushed"; lat="$WORK/lat"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect ghcr.io/esd-univr/hdl-course-toolchain:latest"*) [ -f "\$lat" ] && { echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  *"buildx imagetools inspect"*) [ -f "\$pushed" ] && { echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  "push ghcr.io/esd-univr/hdl-course-toolchain:latest") touch "\$lat"; exit 0 ;;
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

# 8a: a clean, matching qualification record passes the validation gate (the
# full stubbed pipeline then runs to completion — see the 9/10/11/12 blocks)
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
eq "9a full run then moves :latest" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["latest_moved"])')" "True"
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

# 9d: :v1.3.1 manifest present, ledger cannot vouch, and the pull to prove it
# fails -> abort "cannot prove", nothing pushed (resume state d)
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "pull "*) exit 1 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "9d unprovable remote aborts" "$?"
has "9d cannot-prove message" "$out" "cannot prove"
if grep -q "^push ghcr" "$WORK/docker.log"; then bad "9d must not push" "$(cat "$WORK/docker.log")"; else ok; fi
teardown_repo

# 9e: ledger already records image_digest == the live :v1.3.1 digest -> fast
# path, publish_versioned_image neither pulls nor pushes (resume state b)
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
python3 -c "import json;json.dump({'version':'v1.3.1','source_commit':'x','image_digest':'$DIGEST','versioned_ref':'$(ghcr_ref v1.3.1)','latest_moved':False,'tag_published':False,'release_created':False,'updated_at':'now'},open('.out/publish.json','w'),indent=2,sort_keys=True)"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "9e fast path exits 0" "$?" "0"
has "9e says already published" "$out" "already published"
if grep -q "^pull " "$WORK/docker.log"; then bad "9e must not pull" "$(cat "$WORK/docker.log")"; else ok; fi
if grep -q "^push " "$WORK/docker.log"; then bad "9e must not push" "$(cat "$WORK/docker.log")"; else ok; fi
teardown_repo

echo
echo "== publish: move :latest =="

# 10a: happy path — :v1.3.1 pushed, THEN :latest pushed to the same digest
setup_pub
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "10a exits 0" "$?" "0"
grep -q "^push ghcr.io/esd-univr/hdl-course-toolchain:latest\$" "$WORK/docker.log" \
  && ok || bad "10a :latest pushed" "$(cat "$WORK/docker.log")"
eq "10a ledger latest_moved" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["latest_moved"])')" "True"
vln=$(grep -n "^push ghcr.*:v1.3.1\$" "$WORK/docker.log" | head -1 | cut -d: -f1)
lln=$(grep -n "^push ghcr.*:latest\$" "$WORK/docker.log" | head -1 | cut -d: -f1)
{ [ -n "$vln" ] && [ -n "$lln" ] && [ "$vln" -lt "$lln" ]; } \
  && ok || bad "10a :v1.3.1 pushed before :latest (v=$vln l=$lln)" "$(cat "$WORK/docker.log")"
teardown_repo

# 10b: resume — :latest already resolves to the ledger image_digest -> no second
# :latest push, latest_moved still set true
setup_pub
python3 -c "import json;json.dump({'version':'v1.3.1','source_commit':'x','image_digest':'$DIGEST','versioned_ref':'$(ghcr_ref v1.3.1)','latest_moved':False,'tag_published':False,'release_created':False,'updated_at':'now'},open('.out/publish.json','w'),indent=2,sort_keys=True)"
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "10b resume exits 0" "$?" "0"
if grep -q "push .*:latest" "$WORK/docker.log"; then bad "10b must not re-push :latest" "$(cat "$WORK/docker.log")"; else ok; fi
has "10b logs already-at" "$out" "already at"
eq "10b ledger latest_moved" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["latest_moved"])')" "True"
teardown_repo

echo
echo "== publish: git tag =="

# 11a: creates + pushes the annotated tag on the qualified commit
setup_pub
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*)
     t="\${2##*/}"
     if sha=\$(git -C "$WORK/up.git" rev-parse -q --verify "refs/tags/\$t^{commit}" 2>/dev/null); then
       printf '{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}\n' "\$t" "\$sha"
       exit 0
     fi
     echo '{"message":"Not Found"}'; exit 1 ;;
  *"release create"*) echo created ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "11a exits 0" "$?" "0"
eq "11a local tag on the qualified commit" \
   "$(git rev-parse 'v1.3.1^{commit}')" "$(git rev-parse HEAD)"
eq "11a origin has the tag at that commit" \
   "$(git -C "$WORK/up.git" rev-parse 'v1.3.1^{commit}')" "$(git rev-parse HEAD)"
eq "11a tag is annotated" "$(git cat-file -t v1.3.1)" "tag"
eq "11a ledger tag_published" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["tag_published"])')" "True"
teardown_repo

# 11b: resume — local tag already on the right commit -> exit 0, no error
setup_pub
git tag -a v1.3.1 -m x
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "11b resume with correct tag exits 0" "$?" "0"
case "$out" in *"points at"*) bad "11b must not report a conflict" "$out" ;; *) ok ;; esac
teardown_repo

# 11c: conflict — local tag on HEAD~1 -> abort with "points at"
setup_pub
git tag -a v1.3.1 -m x HEAD~1
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "11c wrong local tag aborts" "$?"
has "11c conflict message" "$out" "points at"
teardown_repo

# 11d: conflict — origin already has the tag on a different commit -> abort
setup_pub
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*)
     t="\${2##*/}"
     if sha=\$(git -C "$WORK/up.git" rev-parse -q --verify "refs/tags/\$t^{commit}" 2>/dev/null); then
       printf '{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}\n' "\$t" "\$sha"
       exit 0
     fi
     echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
git -C "$WORK/up.git" tag -a v1.3.1 -m x "$(git rev-parse HEAD~1)"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "11d origin tag conflict aborts" "$?"
has "11d origin conflict message" "$out" "origin tag v1.3.1 points at"
teardown_repo

# 11e: resume — origin already has the tag as an ANNOTATED tag object. GitHub
# returns object.type == "tag" for that, so origin_tag_object_sha must
# dereference it via a second `gh api .../git/tags/<sha>` call (release_lib.sh).
# The gh stub models that exchange directly — no real tag object is needed in
# the bare origin (the qualified commit is not pushed there anyway).
setup_pub
WANT="$(git rev-parse HEAD)"
git tag -a v1.3.1 -m x "$WANT"                      # local tag present + on the qualified commit
TAGOBJ="1111111111111111111111111111111111111111"   # a stand-in annotated-tag-object sha
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
echo "\$*" >> "$WORK/gh.log"
case "\$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*) printf '{"object":{"type":"tag","sha":"%s"}}\n' "$TAGOBJ"; exit 0 ;;
  *"git/tags/$TAGOBJ"*) printf '%s\n' "$WANT"; exit 0 ;;   # gh --jq '.object.sha' already applied
  *"release create"*) echo created ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "11e annotated-tag deref resume exits 0" "$?" "0"
has "11e sees origin already has the tag" "$out" "origin already has"
grep -q "git/tags/$TAGOBJ" "$WORK/gh.log" && ok || bad "11e dereferenced the annotated tag object" "$(cat "$WORK/gh.log")"
teardown_repo

echo
echo "== publish: GitHub Release =="

# 12a: full happy path — assets assembled, notes written, Release created; then a
# full re-run is a clean no-op via the "already created" path.
setup_pub
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
mk="$WORK/rel"
case "\$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*)
     [ -f "\$mk" ] || exit 1
     case "\$*" in
       *"--json tagName"*) echo v1.3.1 ;;
       *"--json assets"*) printf '%s\n' hdl-toolchain install.sh uninstall.sh SHA256SUMS ;;
       *"--json url"*) echo "https://github.com/esd-univr/hdl-course-toolchain/releases/tag/v1.3.1" ;;
       *) echo release ;;
     esac
     exit 0 ;;
  *"release create"*) touch "\$mk"; echo "https://github.com/esd-univr/hdl-course-toolchain/releases/tag/v1.3.1"; exit 0 ;;
  *"git/ref/tags/"*)
     t="\${2##*/}"
     if sha=\$(git -C "$WORK/up.git" rev-parse -q --verify "refs/tags/\$t^{commit}" 2>/dev/null); then
       printf '{"object":{"type":"commit","sha":"%s"}}\n' "\$sha"; exit 0
     fi
     echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "12a publish exits 0" "$?" "0"
test -f .out/dist/SHA256SUMS && ok || bad "12a SHA256SUMS assembled"
grep -q 'hdl-toolchain$' .out/dist/SHA256SUMS && ok || bad "12a SHA256SUMS lists hdl-toolchain"
grep -q 'SHA256SUMS' .out/dist/SHA256SUMS && bad "12a SHA256SUMS must not checksum itself" || ok
eq "12a SHA256SUMS has exactly three lines" \
   "$(grep -c . .out/dist/SHA256SUMS)" "3"
test -f .out/dist/hdl-toolchain && test -f .out/dist/install.sh && test -f .out/dist/uninstall.sh \
   && ok || bad "12a all three release assets copied into .out/dist"
has "12a notes carry the digest" "$(cat .out/dist/NOTES.md)" "sha256:"
has "12a notes say :latest moved" "$(cat .out/dist/NOTES.md)" "latest"
has "12a notes name the versioned ref" "$(cat .out/dist/NOTES.md)" "ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1"
has "12a notes carry the qualification summary" "$(cat .out/dist/NOTES.md)" "qualified at"
has "12a announces the release" "$out" "creating GitHub Release v1.3.1"
has "12a prints the release URL" "$out" "releases/tag/v1.3.1"
has "12a main summary reads the ledger" "$out" "release created: true"
eq "12a ledger release_created" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["release_created"])')" "True"
# full resume: re-run is a clean no-op
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "12a resume exits 0" "$?" "0"
has "12a resume says already created" "$out" "already created"
case "$out" in *"creating GitHub Release"*) bad "12a resume must not re-create" "$out" ;; *) ok ;; esac
eq "12a resume keeps release_created true" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["release_created"])')" "True"
teardown_repo

# 12b: a Release already exists on a DIFFERENT tag -> abort, never touch it
setup_pub
cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*) case "$*" in *"--json tagName"*) echo v9.9.9 ;; *) echo r ;; esac; exit 0 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "12b Release on a different tag aborts" "$?"
has "12b refuses to touch it" "$out" "refusing to touch it"
eq "12b ledger release_created stays False" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["release_created"])')" "False"
teardown_repo

# 12c: a create that died mid-upload left the Release without one asset -> the
# adopt path refuses to call it done and names the missing asset
setup_pub
cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"release view"*)
     case "$*" in
       *"--json tagName"*) echo v1.3.1 ;;
       *"--json assets"*) printf '%s\n' hdl-toolchain install.sh uninstall.sh ;;  # SHA256SUMS missing
       *) echo release ;;
     esac
     exit 0 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "12c missing asset aborts" "$?"
has "12c names the missing asset" "$out" "asset 'SHA256SUMS' is missing"
has "12c gives the upload command" "$out" "gh release upload"
eq "12c ledger release_created stays False" \
   "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["release_created"])')" "False"
teardown_repo

echo
echo "== publish: ledger round-trips (bool + null) =="
setup_pub
rc=0
(
  cd "$WORK/repo" || exit 9
  # shellcheck disable=SC1091
  . scripts/publish-release.sh v1.3.1 >/dev/null 2>&1
  cd "$WORK/repo" || exit 9
  ledger_init v1.3.1 deadcafe "$(ghcr_ref v1.3.1)"
  [ "$(ledger_get latest_moved)" = "false" ]        || exit 1
  ledger_set latest_moved true
  [ "$(ledger_get latest_moved)" = "true" ]         || exit 2
  ledger_set latest_moved false
  [ "$(ledger_get latest_moved)" = "false" ]        || exit 3
  [ "$(ledger_get image_digest)" = "" ]             || exit 4
  ledger_set image_digest sha256:abc123
  [ "$(ledger_get image_digest)" = "sha256:abc123" ] || exit 5
) || rc=$?
eq "ledger_get round-trips latest_moved bool + null image_digest" "$rc" "0"
teardown_repo

echo
echo "release_lib: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
