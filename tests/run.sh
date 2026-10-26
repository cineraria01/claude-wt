#!/usr/bin/env bash
# wt 시험: 임시 폴더에 원격 역할 bare 저장소 + 작업 저장소를 만들어 실제 명령을 돌린다.
# 실제 홈·저장소는 건드리지 않는다(HOME·git 설정을 임시로). 실행: bash tests/run.sh
set -euo pipefail

WT="$(cd "$(dirname "$0")/.." && pwd)/bin/wt"
T=$(cd "$(mktemp -d)" && pwd -P)
cleanup() { [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export WT_SESSION_ID=test-session WT_CLAUDE_PID=$$ VERIFY_LOG="$T/verify.log"
unset CLAUDE_CODE_SESSION_ID WT_FORCE_VERIFY WT_FORCE_FINISH
mkdir -p "$HOME"; : >"$VERIFY_LOG"

pass=0; fail=0
# 실패하면 그 장면의 출력($out, 마지막 30줄)을 보인다 — 흔들리는 실패를 다시 돌리지 않고도 원인을 볼 수 있게.
check() {
  local d=$1; shift
  if "$@"; then echo "  ok   $d"; pass=$((pass + 1)); return 0; fi
  echo "  FAIL $d"; fail=$((fail + 1))
  [ -z "${out-}" ] || { echo "       | 이 장면의 \$out:"; printf '%s\n' "$out" | tail -n 30 | sed 's/^/       | /'; }
}
# 장면 머리: 앞 장면의 $out이 실패 출력에 섞이지 않게 비운다
scene() { out=""; echo "$1"; }
has() { printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; }
hasnt() { ! has "$@"; }
verify_runs() { wc -l <"$VERIFY_LOG" | tr -d ' '; }
start() { "$WT" start "$@" 2>/dev/null | tail -n 1; }   # 마지막 줄이 워크트리 경로
commit() { (cd "$1" && git add -A && git commit -qm "$2"); }
# 다른 저장소에서 원격 브랜치를 앞으로 민다(다른 레인이 먼저 머지된 상황).
push_from_elsewhere() { # 브랜치 파일 내용
  rm -rf "$T/other" && git clone -q "$T/origin.git" "$T/other" && (cd "$T/other" && git checkout -q "$1" \
    && printf '%s\n' "$3" >"$2" && git add -A && git commit -qm "elsewhere $2" && git push -q origin "$1")
}

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
R="$T/repo"; cd "$R"
seq 1 20 >a.txt; echo b >b.txt; echo log >log.txt
echo 'log.txt merge=union' >.gitattributes
mkdir .claude
printf '#!/usr/bin/env bash\necho run >>"$VERIFY_LOG"\neval "${VERIFY_HOOK-}"\n' >.claude/wt-verify.sh; chmod +x .claude/wt-verify.sh   # VERIFY_HOOK: 검증 중에 일어나는 일 흉내
git add -A && git commit -qm init && git push -q -u origin main
git remote set-head origin main
INIT=$(git rev-parse HEAD)
# 원격 v2는 main보다 앞선 장기 브랜치, 로컬 v2는 init에 머물러 main에 이미 들어 있다(gc가 "반영됨"으로 오판하기 쉬운 상태).
git push -q origin "$INIT:refs/heads/v2"
push_from_elsewhere v2 v2.txt "v2 only"
git fetch -q origin; git branch -q v2 "$INIT"

scene "① 다른 기준 레인의 앞선 수·반영 판정"
V1=$(start v2-a --base v2)
echo lane >"$V1/c.txt"; commit "$V1" "v2 lane"
V0=$(start v2-empty --base v2)        # 커밋 없는 v2 레인: v2 기준으론 반영됨, main 기준으론 +1로 오판됐다
out=$("$WT" list 2>&1)
check "v2 레인 +1(main 기준이면 +2)" has "$out" "$V1  wt/v2-a  +1 [기준 v2]"
check "빈 v2 레인 [v2에 반영됨]" has "$out" "$V0  wt/v2-empty  +0 [기준 v2] [v2에 반영됨]"
check "main 반영 표시가 v2 레인에 안 붙음" hasnt "$out" "[main에 반영됨]"

scene "② 기준으로 쓰이는 브랜치를 gc가 지우지 않음"
git branch -q old-feature "$INIT"     # main에 들어간 평범한 브랜치 → 지워져야 함
git branch -q release/1 "$INIT"; git config wt.protect "v2 release/*"
git branch -q long "$INIT"; git push -q origin "$INIT:refs/heads/long"; push_from_elsewhere long l.txt x; git fetch -q origin
out=$("$WT" gc --apply 2>&1)
check "v2 유지(기준 브랜치)" has "$out" "유지(기준 브랜치) 브랜치 v2"
check "wt.protect 패턴 유지" has "$out" "유지(기준 브랜치) 브랜치 release/1"
check "원격이 앞선 브랜치 유지" has "$out" "유지(기준 브랜치) 브랜치 long"
check "반영된 평범한 브랜치는 정리" has "$out" "정리 대상 브랜치 old-feature"
check "로컬 v2 남아 있음" git show-ref --verify --quiet refs/heads/v2
git config --unset wt.protect
git branch -q base2 "$INIT"; git config branch.ghost.wtBase base2   # 원격 없음·main에 반영됨, wtBase로만 쓰임
out=$("$WT" gc 2>&1)
check "wtBase로 쓰이는 브랜치 유지" has "$out" "유지(기준 브랜치) 브랜치 base2"
check "wt.protect 없이도 v2 유지" has "$out" "유지(기준 브랜치) 브랜치 v2"
git config --unset branch.ghost.wtBase; git branch -q -D base2
check "list에 [기준 브랜치]" has "$("$WT" list 2>&1)" "브랜치만 v2  +0 [기준 브랜치]"

scene "③ wt verify 뒤 같은 트리면 finish가 검증을 건너뜀"
echo dirty >>"$V1/c.txt"
check "미커밋이면 wt verify 거절" bash -c "cd '$V1' && ! '$WT' verify 2>/dev/null"
(cd "$V1" && git checkout -q -- c.txt)
(cd "$V1" && "$WT" verify 2>/dev/null)
check "wt verify가 검증 1회" [ "$(verify_runs)" = 1 ]
out=$(cd "$V1/.claude" && "$WT" finish 2>&1) || true   # 하위 폴더에서 실행해도 동작
check "finish가 건너뜀 안내" has "$out" "이미 검증한 코드와 같아 검증을 건너뜁니다"
check "검증 횟수 그대로 1" [ "$(verify_runs)" = 1 ]
check "v2에 머지됨(원격)" git -C "$R" cat-file -e origin/v2:c.txt
check "main에는 안 들어감" bash -c "! git -C '$R' cat-file -e origin/main:c.txt 2>/dev/null"
check "레인 워크트리 삭제" [ ! -e "$V1" ]
V2=$(start v2-b --base v2)
echo b2 >"$V2/d.txt"; commit "$V2" "v2 lane b"
(cd "$V2" && "$WT" verify 2>/dev/null)
push_from_elsewhere v2 e.txt "moved"   # 기준이 움직여 rebase 뒤 트리가 달라진다
out=$(cd "$V2" && "$WT" finish 2>&1) || true
check "기준이 바뀌면 다시 검증(횟수 3)" [ "$(verify_runs)" = 3 ]
check "다시 검증 때 건너뜀 안내 없음" hasnt "$out" "건너뜁니다"
V3=$(start v2-c --base v2)
echo c3 >"$V3/f.txt"; commit "$V3" "v2 lane c"
(cd "$V3" && "$WT" verify 2>/dev/null)
(cd "$V3" && WT_FORCE_VERIFY=1 "$WT" finish >/dev/null 2>&1) || true
check "WT_FORCE_VERIFY=1이면 같은 트리여도 검증(횟수 5)" [ "$(verify_runs)" = 5 ]

scene "④ 줄 단위 충돌 예고"
A=$(start lane-a); B=$(start lane-b); C=$(start lane-c)
sed -i.bak '2s/.*/A2/' "$A/a.txt"; rm "$A/a.txt.bak"; echo a >>"$A/log.txt"; commit "$A" "a: line 2"
sed -i.bak '2s/.*/B2/' "$B/a.txt"; rm "$B/a.txt.bak"; echo b >>"$B/log.txt"   # B는 미커밋 상태로 둔다
sed -i.bak '19s/.*/C19/' "$C/a.txt"; rm "$C/a.txt.bak"; commit "$C" "c: line 19"
out=$(cd "$A" && "$WT" overlap 2>&1 || true)
check "같은 줄(미커밋 포함) → 충돌 예상" has "$out" "충돌 예상 $B (wt/lane-b)"
check "다른 줄 → 자동 병합 가능" has "$out" "겹침(자동 병합 가능) $C (wt/lane-c)"
check "merge=union 파일은 빠짐" hasnt "$out" "log.txt"
check "다른 기준(v2) 레인은 안 봄" hasnt "$out" "v2-empty"
push_from_elsewhere main a.txt "$(seq 1 20 | sed '2s/.*/MAIN2/')"; git fetch -q origin
out=$(cd "$C" && "$WT" overlap 2>&1 || true)
check "기준과 같은 줄 아님 → 기준 충돌 없음" hasnt "$out" "충돌 예상 기준"
out=$(cd "$A" && "$WT" overlap 2>&1 || true)
check "기준에 먼저 들어간 같은 줄 → 기준 충돌 예상" has "$out" "충돌 예상 기준 origin/main"
out=$("$WT" list --conflicts 2>&1) || true
check "list --conflicts에 레인 쌍 충돌" has "$out" "충돌 예상 $B (wt/lane-b)"
out=$(cd "$C" && "$WT" finish 2>&1) || true
check "finish 시작 때 한 줄 요약" has "$out" "겹치지만 자동 병합 가능"

scene "⑤ 기존 동작 회귀"
# .worktreeinclude 복사가 중간에서 실패하면(뒤 파일은 성공해도) start가 실패해야 한다.
printf 'aa.secret\nzz.secret\n' >"$R/.worktreeinclude"; printf 'aa.secret\nzz.secret\n.worktreeinclude\n' >"$R/.git/info/exclude"
mkdir "$R/aa.secret"; : >"$R/aa.secret/x"; chmod 000 "$R/aa.secret"; : >"$R/zz.secret"
rc=0; "$WT" start include-fail >/dev/null 2>&1 || rc=$?
chmod 755 "$R/aa.secret"; rm -rf "$R/aa.secret" "$R/zz.secret" "$R/.worktreeinclude"; : >"$R/.git/info/exclude"
check ".worktreeinclude 복사가 중간에서 실패하면 start 실패" [ "$rc" != 0 ]
"$WT" gc --apply >/dev/null 2>&1 || true; git -C "$R" worktree remove --force "$R.wt/include-fail" 2>/dev/null || true; git -C "$R" branch -D wt/include-fail >/dev/null 2>&1 || true
M=$(start plain)
echo new >"$M/g.txt"
check "미커밋이면 finish 거절" bash -c "cd '$M' && ! '$WT' finish 2>/dev/null"
commit "$M" "plain lane"
out=$(cd "$M" && "$WT" finish 2>&1) || true
check "main 기준 start→finish 머지" git -C "$R" cat-file -e origin/main:g.txt
check "메인 폴더 fast-forward" [ -f "$R/g.txt" ]
check "브랜치 삭제" bash -c "! git -C '$R' show-ref --verify --quiet refs/heads/wt/plain"
mkdir -p "$T/bin"; ln -s "$(command -v sleep)" "$T/bin/claude"; "$T/bin/claude" 300 & FAKE_PID=$!; disown "$FAKE_PID"
O=$(start owned); echo o >"$O/h.txt"; commit "$O" "owned"
printf 'other-session %s 2026-01-01T00:00\n' "$FAKE_PID" >"$(git -C "$O" rev-parse --absolute-git-dir)/wt-owner"
check "list에 [다른 세션 사용 중]" has "$("$WT" list 2>&1)" "[다른 세션 사용 중 pid $FAKE_PID"
check "다른 세션 레인 finish 거절" bash -c "cd '$O' && ! '$WT' finish 2>/dev/null"
check "gc가 다른 세션 레인 유지" has "$("$WT" gc --apply 2>&1)" "유지(다른 세션 사용 중) $O"
check "레인 남아 있음" [ -d "$O" ]

# 커밋 없는 finish(정리만). 변수 바로 뒤에 한글이 붙으면 bash가 한글 바이트까지 변수 이름으로 읽어
# set -u에서 멈춘다(en_US.UTF-8 등). 변수는 ${이름}으로 감싸야 한다.
E=$(start empty-finish)
rc=0; out=$(cd "$E" && LC_ALL=en_US.UTF-8 "$WT" finish 2>&1) || rc=$?
check "커밋 없는 finish가 정리만 하고 성공" [ "$rc" = 0 ]
check "정리만 안내" has "$out" "새로 들어갈 커밋이 없습니다"
check "빈 레인 정리됨" [ ! -e "$E" ]
scene "⑥ 합치기 커밋이 있는 통합 레인"
# 두 하위 브랜치가 같은 줄을 고치고 통합 레인이 그 충돌을 merge로 풀었다. rebase는 이를 한 줄로 다시 쌓아 같은 충돌을 또 냈다.
I=$(start integrate)
(cd "$I" && git checkout -qb sub1 && sed -i.bak 's/^5$/five-a/' a.txt && rm a.txt.bak && git commit -qam sub1 \
  && git checkout -q wt/integrate && git checkout -qb sub2 && sed -i.bak 's/^5$/five-b/' a.txt && rm a.txt.bak && git commit -qam sub2 \
  && git checkout -q wt/integrate && git merge -q --no-ff sub1 -m m1 && { git merge -q --no-ff sub2 -m m2 >/dev/null 2>&1 || true; } \
  && sed -i.bak 's/^<<<<<<<.*$//; s/^=======$//; s/^>>>>>>>.*$//' a.txt && rm a.txt.bak && git commit -qam m2 && git branch -qD sub1 sub2)
rc=0; out=$(cd "$I" && "$WT" finish 2>&1) || rc=$?
check "기준 그대로인 통합 레인 finish 성공" [ "$rc" = 0 ]
check "rebase 생략 안내" has "$out" "rebase 없이 진행합니다"
J=$(start integrate2)
(cd "$J" && git checkout -qb s1 && echo x >j1.txt && git add -A && git commit -qm s1 && git checkout -q wt/integrate2 && git merge -q --no-ff s1 -m m && git branch -qD s1)
push_from_elsewhere main moved.txt moved
rc=0; out=$(cd "$J" && "$WT" finish 2>&1) || rc=$?
check "기준이 움직인 통합 레인은 merge로 받아 성공" [ "$rc" = 0 ]
check "merge 안내" has "$out" "rebase 대신 origin/main을 merge합니다"
check "두 레인 내용 모두 main에" bash -c "git -C '$R' cat-file -e origin/main:j1.txt && git -C '$R' cat-file -e origin/main:moved.txt"

scene "⑦ 머지 잠금(flock): 쥔 쪽이 살아 있으면 기다리고, 죽으면 바로 풀림"
LOCK="$(cd "$(git -C "$R" rev-parse --git-common-dir)" && pwd -P)/wt-merge.lock"
hold() { ( exec 9>>"$LOCK"; python3 -I -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'; echo holder >"$LOCK"; exec sleep "$1" ) & }
hold 300; H=$!; sleep 0.5; kill -9 "$H"; wait "$H" 2>/dev/null || true
K=$(start after-crash); echo k >"$K/k.txt"; commit "$K" "after crash"
rc=0; out=$(cd "$K" && "$WT" finish 2>&1) || rc=$?
check "강제 종료된 쪽의 잠금은 기다리지 않고 finish 성공" bash -c "[ $rc = 0 ]"
check "대기 안내 없음" hasnt "$out" "기다립니다"
K=$(start after-wait); echo k2 >"$K/k2.txt"; commit "$K" "after wait"
hold 3; sleep 0.5
rc=0; out=$(cd "$K" && "$WT" finish 2>&1) || rc=$?
check "살아 있는 동안 기다렸다가 성공" bash -c "[ $rc = 0 ]"
check "대기 안내" has "$out" "다른 finish·train(pid holder)이 머지 중이라 기다립니다"
# git이 띄운 오래 사는 프로세스(fsmonitor 훅의 백그라운드 등)가 잠금 fd를 물려받으면 끝난 뒤에도 잠금이 남았다.
printf '#!/usr/bin/env bash\nsleep 4 </dev/null >/dev/null 2>&1 &\nexit 1\n' >"$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
git -C "$R" config core.fsmonitor "$T/fsmon.sh"
K=$(start fd-leak); echo k3 >"$K/k3.txt"; commit "$K" "fd leak"
(cd "$K" && "$WT" finish >/dev/null 2>&1)
K=$(start fd-leak2); echo k4 >"$K/k4.txt"; commit "$K" "fd leak 2"
rc=0; out=$(cd "$K" && "$WT" finish 2>&1) || rc=$?
git -C "$R" config --unset core.fsmonitor
check "git 자식 프로세스가 잠금을 물려받지 않음(바로 다음 finish가 안 기다림)" bash -c "[ $rc = 0 ]" 
check "  └ 대기 안내 없음" hasnt "$out" "기다립니다"

scene "⑧ wt train: 쌓기·충돌 레인 빼기·검증 한 번·레인별 커밋"
git -C "$R" fetch -q origin; BEFORE=$(git -C "$R" rev-parse origin/main)
T1=$(start t1); echo t1 >"$T1/t1.txt"; commit "$T1" "t1: 새 파일"
T2=$(start t2); sed -i.bak '10s/.*/T2/' "$T2/a.txt"; rm "$T2/a.txt.bak"; commit "$T2" "t2: 10번 줄"
(cd "$T2" && echo t2b >t2.txt && git add -A && git commit -qm "t2: 둘째 커밋")
T3=$(start t3); sed -i.bak '10s/.*/T3/' "$T3/a.txt"; rm "$T3/a.txt.bak"; commit "$T3" "t3: 같은 줄"
T4=$(start t4)   # 커밋 없는 레인
git -C "$R" tag wt/t1 "$BEFORE"        # 레인과 같은 이름의 태그(기준에 있는 커밋): 태그를 머지하면 안 됨
git -C "$R" config merge.ff false      # --squash와 같이 못 쓰는 설정
runs=$(verify_runs)
rc=0; out=$(cd "$T1" && "$WT" train t1 ../t2 "$T3" t4 2>&1) || rc=$?   # 레인 안에서 상대 경로로 줘도 됨
git -C "$R" tag -d wt/t1 >/dev/null; git -C "$R" config --unset merge.ff
check "충돌로 뺀 레인이 있으면 종료 코드 3" [ "$rc" = 3 ]
check "검증은 한 번" [ "$(verify_runs)" = $((runs + 1)) ]
check "t1·t2 내용이 main에" bash -c "git -C '$R' cat-file -e origin/main:t1.txt && git -C '$R' cat-file -e origin/main:t2.txt && [ \"\$(git -C '$R' show origin/main:a.txt | sed -n 10p)\" = T2 ]"
check "레인마다 커밋 하나(2개)" [ "$(git -C "$R" rev-list --count "$BEFORE..origin/main")" = 2 ]
check "t2는 두 커밋을 squash" has "$(git -C "$R" log -1 --format=%B origin/main)" "* t2: 둘째 커밋"
check "충돌 레인 안내" has "$out" "충돌로 뺌: wt/t3"
check "충돌 레인은 남음" [ -d "$T3" ]
check "머지·빈 레인은 정리" bash -c "[ ! -e '$T1' ] && [ ! -e '$T2' ] && [ ! -e '$T4' ]"
check "통합 워크트리 정리" bash -c "! git -C '$R' worktree list | grep -F .train- >/dev/null"
check "메인 폴더 fast-forward" [ -f "$R/t1.txt" ]
rc=0; out=$(cd "$T3" && "$WT" finish 2>&1) || rc=$?
check "남은 충돌 레인은 finish에서 rebase 충돌" has "$out" "rebase 충돌"
(cd "$T3" && git rebase --abort)

scene "⑨ wt train: 거절·실패하면 아무것도 머지 안 함"
git -C "$R" fetch -q origin; BEFORE=$(git -C "$R" rev-parse origin/main)
U1=$(start u1); echo u1 >"$U1/u1.txt"; commit "$U1" "u1"
U2=$(start u2); printf '#!/usr/bin/env bash\nexit 1\n' >"$U2/.claude/wt-verify.sh"; commit "$U2" "u2: 검증 깨짐"
rc=0; out=$("$WT" train u1 u2 2>&1) || rc=$?
check "검증 실패면 train 실패" [ "$rc" = 1 ]
check "실패 안내" has "$out" "묶음 검증 실패. 아무것도 머지하지 않았습니다"
git -C "$R" fetch -q origin
check "main 그대로" [ "$(git -C "$R" rev-parse origin/main)" = "$BEFORE" ]
check "레인 둘 다 남음" bash -c "[ -d '$U1' ] && [ -d '$U2' ]"
check "실패해도 통합 워크트리 정리" bash -c "! git -C '$R' worktree list | grep -F .train- >/dev/null"
check "기준이 다른 레인 섞으면 거절" has "$("$WT" train u1 v2-empty 2>&1 || true)" "기준이 다른 레인은 함께 묶지 못합니다"
check "다른 세션 레인은 거절" has "$("$WT" train u1 owned 2>&1 || true)" "다른 세션이 쓰는 워크트리입니다"
git -C "$R" worktree add -q "$T/v2-checkout" v2
check "기준 브랜치(v2) 워크트리는 거절" has "$("$WT" train v2 2>&1 || true)" "원격 사본이 로컬보다 앞선 브랜치라 묶지 않습니다: v2"
check "v2 원격 그대로" git -C "$R" show-ref --verify --quiet refs/remotes/origin/v2
git -C "$R" worktree remove "$T/v2-checkout"
git -C "$R" worktree lock --reason manual "$U1"
check "git worktree lock(에이전트 외 사유) 레인은 거절" has "$("$WT" train u1 2>&1 || true)" "잠긴 워크트리입니다"
git -C "$R" worktree unlock "$U1"

scene "⑩ wt train: 검증 중 레인에 생긴 변경은 지우지 않음"
W1=$(start w1); echo w1 >"$W1/w1.txt"; commit "$W1" "w1"
W2=$(start w2); echo w2 >"$W2/w2.txt"; commit "$W2" "w2"
rc=0; out=$(VERIFY_HOOK="(cd '$W1' && echo late >late.txt && git add -A && git commit -qm late); echo dirty >>'$W2/w2.txt'" "$WT" train w1 w2 2>&1) || rc=$?
check "남긴 레인이 있으면 종료 코드 3" [ "$rc" = 3 ]
check "쌓은 내용은 main에" bash -c "git -C '$R' cat-file -e origin/main:w1.txt && git -C '$R' cat-file -e origin/main:w2.txt"
check "늦은 커밋은 아직 main에 없음" bash -c "! git -C '$R' cat-file -e origin/main:late.txt 2>/dev/null"
check "두 레인 모두 남음(커밋·미커밋 보존)" bash -c "[ -f '$W1/late.txt' ] && grep -q dirty '$W2/w2.txt'"
check "남긴 레인 안내" has "$out" "쌓은 뒤 새 커밋·미커밋 변경이 생겨 남긴 레인"

scene "⑪ gc: 강제 종료로 남은 train 통합 워크트리"
DEAD=$(bash -c 'echo $$')
git -C "$R" worktree add -q --detach "$R.wt/.train-$DEAD" origin/main
check "끝난 pid의 .train- 워크트리 정리" has "$("$WT" gc --apply 2>&1)" "정리 대상(끝난 train의 통합 워크트리) $R.wt/.train-$DEAD"
check "실제로 지워짐" [ ! -e "$R.wt/.train-$DEAD" ]

scene "⑫-0 기계 간 선점: wt claim / unclaim / claims"
cd "$R"
claim_at() { # 이름 host pid 커밋시각 — 다른 기계·오래된 선점을 직접 만들어 origin에 둔다
  local s; s=$(GIT_COMMITTER_DATE="$4" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt claim $1" -m "host=$2 pid=$3 at=old note=") \
    && git push -q origin "$s:refs/wt-claims/$1"
}
rsha() { git ls-remote origin "refs/wt-claims/$1" | cut -f1; }
rc=0; S1=$("$WT" claim rel-1 --pid $$ --note "첫 공개" 2>/dev/null) || rc=$?
check "첫 선점 0 + sha" bash -c "[ $rc = 0 ] && [[ '$S1' =~ ^[0-9a-f]{40}$ ]]"
check "origin에 refs/wt-claims/rel-1" [ "$(rsha rel-1)" = "$S1" ]
rc=0; out=$("$WT" claim rel-1 2>/dev/null) || rc=$?
check "두 번째 선점 3" [ "$rc" = 3 ]
check "선점자 한 줄(sha·host·pid·note)" has "$out" "sha=$S1 host=$(hostname -s) pid=$$ at="
check "  └ note" has "$out" "note=첫 공개"
check "엉뚱한 sha로 unclaim하면 1" bash -c "! '$WT' unclaim rel-1 0000000000000000000000000000000000000000 2>/dev/null"
check "  └ 선점은 남음" [ "$(rsha rel-1)" = "$S1" ]
out=$("$WT" claims 2>&1)
check "claims 목록에 이름·선점자" has "$out" "rel-1  host=$(hostname -s) pid=$$"
check "  └ 나이" has "$out" "(0분 전)"
check "맞는 sha로 unclaim하면 지움" bash -c "'$WT' unclaim rel-1 '$S1' && [ -z \"\$(git ls-remote origin refs/wt-claims/rel-1)\" ]"
check "이미 없으면 unclaim 0" "$WT" unclaim rel-1 "$S1"
check "빈 목록" has "$("$WT" claims 2>&1)" "선점 없음"
"$WT" claim rel-2 >/dev/null 2>&1
s=$(date +%s); rc=0; out=$("$WT" claim rel-2 --wait 2 2>&1) || rc=$?
check "--wait 시간 초과면 3" [ "$rc" = 3 ]
check "  └ 기다린 시간 2초 이상" [ $(($(date +%s) - s)) -ge 2 ]
check "  └ 대기 안내" has "$out" "최대 2초 기다립니다"
R2=$(rsha rel-2); (sleep 1; "$WT" unclaim rel-2 "$R2") & UP=$!
rc=0; "$WT" claim rel-2 --wait 15 >/dev/null 2>&1 || rc=$?; wait "$UP"
check "--wait 중에 풀리면 잡음" bash -c "[ $rc = 0 ] && [ '$(rsha rel-2)' != '$R2' ]"
claim_at old elsewhere 1 "2020-01-01T00:00:00Z"
rc=0; out=$("$WT" claim old 2>&1) || rc=$?
check "오래된 선점(--stale 초과)은 넘겨받음" [ "$rc" = 0 ]
check "  └ 경고" has "$out" "경고: 낡은 선점을 넘겨받습니다(old)"
claim_at young elsewhere 1 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rc=0; "$WT" claim young --stale 3600 >/dev/null 2>&1 || rc=$?
check "다른 host의 pid는 끝났는지 몰라 넘겨받지 않음(3)" [ "$rc" = 3 ]
"$WT" claim dead --pid "$DEAD" >/dev/null 2>&1
rc=0; out=$("$WT" claim dead 2>&1) || rc=$?
check "같은 host의 끝난 pid 선점은 넘겨받음" [ "$rc" = 0 ]
check "  └ 경고" has "$out" "낡은 선점을 넘겨받습니다(dead)"
check "잘못된 이름 거절" bash -c "! '$WT' claim 'a/b' 2>/dev/null"
git init -q "$T/noorigin"; (cd "$T/noorigin" && git commit -q --allow-empty -m x)
rc=0; out=$(cd "$T/noorigin" && "$WT" claim x 2>&1) || rc=$?
check "origin 없으면 claim 1 + 안내" bash -c "[ $rc = 1 ] && printf '%s' '$out' | grep -F 'origin 원격이 없어' >/dev/null"
check "인자 없는 wt claim은 워크트리 맡기 그대로" has "$(cd "$U1" && "$WT" claim 2>&1)" "이 세션이 $U1 를 맡습니다"
for n in rel-2 old young dead; do git push -q origin ":refs/wt-claims/$n" 2>/dev/null || true; done

scene "⑫ wt train: GitHub 경로(gh 흉내, 원격 주소에 github.com)"
G="$T/github.com/gh.git"; GS="$T/ghstate"; mkdir -p "$T/github.com" "$GS"
git clone -q --bare "$T/origin.git" "$G"
cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
echo "gh $*" >>"$GH_STATE/calls"
case "$1 $2" in
  "pr create") shift 2; while [ $# -gt 0 ]; do case $1 in --base) b=$2; shift 2 ;; --head) h=$2; shift 2 ;; *) shift ;; esac; done
               echo "$b $h" >"$GH_STATE/pr"; rm -f "$GH_STATE/merged"; echo "https://github.com/o/r/pull/7" ;;
  "pr list") [ -f "$GH_STATE/pr" ] && [ ! -f "$GH_STATE/merged" ] && echo 7 || true ;;
  "pr merge") [ -z "${GH_FAIL_MERGE-}" ] || exit 1
              shift 3; m="" want="" subj=squash; while [ $# -gt 0 ]; do case $1 in --rebase|--squash) m=$1; shift ;; --match-head-commit) want=$2; shift 2 ;; --subject) subj=$2; shift 2 ;; *) shift ;; esac; done
              [ -z "${GH_FAIL_REBASE-}" ] || [ "$m" != --rebase ] || exit 1   # rebase 머지를 허용하지 않는 저장소 흉내
              read -r b h <"$GH_STATE/pr"; c=$(mktemp -d); git clone -q "$GH_ORIGIN" "$c"
              # GitHub처럼: 헤드가 --match-head-commit과 다르면 거절. 기준이 움직였어도 같은 줄 충돌만 없으면 머지한다.
              [ -z "$want" ] || [ "$(git -C "$c" rev-parse "origin/$h")" = "$want" ] || { rm -rf "$c"; exit 1; }
              case $m in
                --rebase) (cd "$c" && git checkout -q "$h" && git rebase -q "origin/$b" && git push -q origin "HEAD:$b") ;;
                --squash) (cd "$c" && git checkout -q "$b" && git merge -q --squash "origin/$h" && git commit -qm "$subj" && git push -q origin "HEAD:$b") ;;
                *) exit 1 ;;
              esac; rm -rf "$c"; touch "$GH_STATE/merged" ;;
  "pr close") read -r b h <"$GH_STATE/pr"; git --git-dir="$GH_ORIGIN" branch -D "$h" >/dev/null; rm -f "$GH_STATE/pr" ;;   # 닫힌 PR은 pr list(open)에 안 나옴
  "pr view") echo MERGED ;;
esac
GH
chmod +x "$T/bin/gh"
git clone -q "$G" "$T/ghrepo" 2>/dev/null; GR="$T/ghrepo"; git -C "$GR" remote set-head origin main
export GH_STATE="$GS" GH_ORIGIN="$G"
gstart() { (cd "$GR" && PATH="$T/bin:$PATH" "$WT" start "$1" 2>/dev/null | tail -n 1); }
GB=$(git -C "$GR" rev-parse origin/main)
G1=$(gstart g1); echo 1 >"$G1/g1.txt"; commit "$G1" "g1 추가"
G2=$(gstart g2); echo 2 >"$G2/g2.txt"; commit "$G2" "g2 추가"
git -C "$G2" push -q origin wt/g2   # 원격에도 있던 레인 브랜치
rc=0; out=$(cd "$GR" && PATH="$T/bin:$PATH" GH_FAIL_MERGE=1 "$WT" train g1 g2 2>&1) || rc=$?
check "머지 실패면 train 실패" [ "$rc" = 1 ]
check "실패한 PR을 닫음" has "$(cat "$GS/calls")" "gh pr close 7 --delete-branch"
check "train 브랜치 원격에서 정리" bash -c "! git --git-dir='$G' for-each-ref refs/heads/wt/train- | grep . >/dev/null"
check "레인 그대로" bash -c "[ -d '$G1' ] && [ -d '$G2' ]"
rc=0; out=$(cd "$GR" && PATH="$T/bin:$PATH" "$WT" train --title "묶음" g1 g2 2>&1) || rc=$?
git -C "$GR" fetch -q --prune origin
check "GitHub 경로 train 성공" [ "$rc" = 0 ]
check "rebase 머지로 레인별 커밋 2개" [ "$(git -C "$GR" rev-list --count "$GB..origin/main")" = 2 ]
check "PR 제목은 --title" has "$(cat "$GS/calls")" "--title 묶음"
check "원격 레인 브랜치·train 브랜치 정리" bash -c "[ -z \"\$(git --git-dir='$G' for-each-ref --format='%(refname)' refs/heads/wt/)\" ]"
check "메인 폴더 fast-forward" [ -f "$GR/g2.txt" ]
check "train 머지에 --match-head-commit" has "$(cat "$GS/calls")" "--rebase --match-head-commit"
check "train 번호표를 지우고 끝남" bash -c "[ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"

scene "⑫-1 차례를 받은 뒤 재확인: 검증 중에 다른 기계가 main에 머지하면 차례를 쥔 채 다시 올려 검증"
export WT_QUEUE_POLL=1 WT_QUEUE_BEAT=2   # 갱신 2초 → 같은 host의 끝난 pid는 갱신이 6초 넘게 멈춰야 낡음
export WT_QUEUE_LATE=2   # 늦은 반영 재확인 창(기본 30초): 남이 지운 장면의 정리 프로세스가 빨리 끝나게. 늦은 반영 장면만 30초
qempty() { [ -z "$(git ls-remote "$G" 'refs/wt-queue/*')" ]; }
# 대기열 번호표 수(_head 제외)가 n이 될 때까지 기다린다(최대 15초).
qwait_n() { local c; for _ in $(seq 1 30); do c=$(git ls-remote "$G" 'refs/wt-queue/main/*' | grep -vc '/_head$' || true); [ "$c" = "$1" ] && return 0; sleep 0.5; done; return 1; }
wq() { (cd "$GR" && PATH="$T/bin:$PATH" exec "$WT" queue "$@"); }
# 정리용 leave: 앞 단계가 실패해 번호표 ref가 비었거나 다른 글이면 부르지 않는다(사용법 오류로 스위트가 멈추지 않게)
wql() { case ${1-} in refs/wt-queue/*) wq leave "$1" ;; esac; }
untilf() { for _ in $(seq 1 30); do grep -F -- "$2" "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
ELSE="rm -rf '$T/gh-else' && git clone -q '$G' '$T/gh-else' && (cd '$T/gh-else' && echo \$RANDOM >else-\$RANDOM.txt && git add -A && git commit -qm else && git push -q origin main)"
F1=$(gstart f1); echo f1 >"$F1/f1.txt"; commit "$F1" "f1 추가"
runs=$(verify_runs); rm -f "$T/moved"; : >"$GS/calls"
rc=0; out=$(cd "$F1" && PATH="$T/bin:$PATH" VERIFY_HOOK="[ -f '$T/moved' ] || { touch '$T/moved'; $ELSE; }" "$WT" finish 2>&1) || rc=$?
git -C "$GR" fetch -q origin
check "finish 성공" [ "$rc" = 0 ]
check "검증 2회(움직인 뒤 다시)" [ "$(verify_runs)" = $((runs + 2)) ]
check "차례 받음 안내" has "$out" "머지 차례를 받았습니다(main/"
check "다시 올림 안내" has "$out" "검증하는 사이 origin/main이 움직였습니다"
check "두 커밋 모두 origin main에" bash -c "git -C '$GR' cat-file -e origin/main:f1.txt && git -C '$GR' log --format=%s origin/main | grep -x else >/dev/null"
check "squash 머지에 --match-head-commit" has "$(cat "$GS/calls")" "--squash --match-head-commit"
check "번호표·차례를 지우고 끝남" qempty
F2=$(gstart f2); echo f2 >"$F2/f2.txt"; commit "$F2" "f2 추가"
rc=0; out=$(cd "$F2" && PATH="$T/bin:$PATH" VERIFY_HOOK="$ELSE" "$WT" finish 2>&1) || rc=$?
check "대기열 밖에서 검증마다 움직이면 5번 뒤 멈춤" bash -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -F 'main가 계속 움직여 머지하지 못했습니다' >/dev/null" _ "$out"
check "  └ 번호표 남기지 않음" qempty
check "  └ 워크트리 남음" [ -d "$F2" ]
git -C "$GR" fetch -q origin
check "  └ f2는 main에 없음" bash -c "! git -C '$GR' cat-file -e origin/main:f2.txt 2>/dev/null"

scene "⑫-2 공개 흉내: 다른 기계의 release 번호표가 차례를 쥔 동안 finish·train은 기다렸다 머지"
REL=$(WT_HOST=builder wq enter release --pid $$ --note "공개 흉내" 2>/dev/null)
check "빈 대기열이면 enter가 바로 번호표 ref 출력" bash -c "[[ '$REL' =~ ^refs/wt-queue/main/[0-9]{13}-builder-$$\$ ]]"
check "  └ 차례 표시(_head)" [ -n "$(git ls-remote "$G" refs/wt-queue/main/_head)" ]
(cd "$F2" && PATH="$T/bin:$PATH" exec "$WT" finish >"$T/wait.out" 2>&1) & WP=$!
untilf "$T/wait.out" "머지 순번"
check "finish가 공개 뒤에서 순번 안내" has "$(cat "$T/wait.out")" "머지 순번 2/2 · 앞: builder release(0분째)"
out=$(wq 2>&1)
check "wt queue 목록: 1번이 공개 [차례]" bash -c "printf '%s\n' \"\$1\" | grep -E '^  1\. release  builder  release  \(0분째\) \[차례\]  $REL  공개 흉내$' >/dev/null" _ "$out"
check "  └ 2번이 finish(merge, 레인)" has "$out" "2. normal  $(hostname -s)  merge wt/f2 (0분째)"
sleep 2
git -C "$GR" fetch -q origin
check "기다리는 동안 머지하지 않음" bash -c "! git -C '$GR' cat-file -e origin/main:f2.txt 2>/dev/null"
check "wt queue leave 성공" wq leave "$REL"
rc=0; wait "$WP" || rc=$?
git -C "$GR" fetch -q origin
check "공개가 놓은 뒤 finish 머지" bash -c "[ $rc = 0 ] && git -C '$GR' cat-file -e origin/main:f2.txt"
check "  └ 대기열 비움" qempty
check "이미 없는 번호표 leave는 0" wq leave "$REL"
# Ctrl-C: 기다리던 finish가 끝나면 자기 번호표를 지운다(남의 차례는 그대로).
REL=$(WT_HOST=builder wq enter release --pid $$ 2>/dev/null)
F3=$(gstart f3); echo f3 >"$F3/f3.txt"; commit "$F3" "f3 추가"
(cd "$F3" && PATH="$T/bin:$PATH" exec "$WT" finish >"$T/wait.out" 2>&1) & WP=$!
untilf "$T/wait.out" "머지 순번"; qwait_n 2
kill "$WP"; pkill -P "$WP" 2>/dev/null || true; wait "$WP" 2>/dev/null || true
check "Ctrl-C 뒤 자기 번호표 지움" qwait_n 1
check "  └ 공개 번호표·차례는 그대로" bash -c "[ -n \"\$(git ls-remote '$G' '$REL')\" ] && [ -n \"\$(git ls-remote '$G' refs/wt-queue/main/_head)\" ]"
# train: 묶음 하나가 번호표 하나(kind train)
H1=$(gstart h1); echo h1 >"$H1/h1.txt"; commit "$H1" "h1 추가"
(cd "$GR" && PATH="$T/bin:$PATH" exec "$WT" train h1 f3 >"$T/train.out" 2>&1) & WP=$!
untilf "$T/train.out" "머지 순번"
check "train은 번호표 하나(kind train, 레인 메모)" bash -c "printf '%s\n' \"\$1\" | grep -E '^  2\. normal  .*  train  \(0분째\)  refs/wt-queue/main/.*  h1 f3$' >/dev/null" _ "$(wq 2>&1)"
wql "$REL"
rc=0; wait "$WP" || rc=$?
git -C "$GR" fetch -q origin
check "  └ 공개가 놓은 뒤 train 머지" bash -c "[ $rc = 0 ] && git -C '$GR' cat-file -e origin/main:h1.txt && git -C '$GR' cat-file -e origin/main:f3.txt"
check "  └ 대기열 비움" qempty
# 머지 실패도 번호표를 지운다
F4=$(gstart f4); echo f4 >"$F4/f4.txt"; commit "$F4" "f4 추가"
rc=0; (cd "$F4" && PATH="$T/bin:$PATH" GH_FAIL_MERGE=1 "$WT" finish >/dev/null 2>&1) || rc=$?
check "머지 실패면 finish 1 + 번호표 지움" bash -c "[ $rc = 1 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
check "잘못된 --priority 거절" bash -c "cd '$F4' && ! PATH='$T/bin:$PATH' '$WT' finish --priority urgent 2>/dev/null"
rc=0; out=$(cd "$F4" && PATH="$T/bin:$PATH" "$WT" finish --priority critical 2>&1) || rc=$?
check "finish --priority critical 머지" [ "$rc" = 0 ]

scene "⑫-3 순번: 등급 → 번호, 차례를 쥔 번호표는 밀려나지 않음"
order() { wq 2>/dev/null | sed -n 's/^  [0-9]*\. [a-z]*  \([^ ]*\) .*/\1/p' | paste -sd ' ' -; }
QA=$(WT_HOST=ha wq enter merge --pid $$ 2>/dev/null)
bgq() { local h=$1; shift; (cd "$GR" && WT_HOST=$h PATH="$T/bin:$PATH" exec "$WT" queue enter "$@" --pid $$ --wait 60 >"$T/q-$h.out" 2>/dev/null) & }
bgq hb merge; PB=$!; qwait_n 2
bgq hc merge --priority critical; qwait_n 3
bgq hd release; PD=$!; qwait_n 4
bgq he merge; PE=$!; qwait_n 5
check "차례 쥔 normal 맨 앞, 그다음 critical → release → normal(먼저 온 순)" [ "$(order)" = "ha hc hd hb he" ]
check "  └ 기다리는 쪽은 아직 출력 없음" bash -c "[ ! -s '$T/q-hc.out' ] && [ ! -s '$T/q-hb.out' ]"
wql "$QA"
check "놓으면 critical이 차례를 받음" untilf "$T/q-hc.out" "refs/wt-queue/main/"
check "  └ 나머지는 그대로 기다림" bash -c "[ ! -s '$T/q-hd.out' ] && [ ! -s '$T/q-hb.out' ]"
bgq hf merge --priority critical; qwait_n 5
check "차례 쥔 critical 뒤에 새 critical, 그다음 release·normal" [ "$(order)" = "hc hf hd hb he" ]
wql "$(cat "$T/q-hc.out")"
check "다음 차례는 새 critical" untilf "$T/q-hf.out" "refs/wt-queue/main/"
kill "$PB" "$PD" "$PE" 2>/dev/null; wait "$PB" "$PD" "$PE" 2>/dev/null || true
wql "$(cat "$T/q-hf.out")"
check "기다리다 끝난 enter는 번호표를 지움" qempty

scene "⑫-4 낡은 번호표·시간 초과"
# 다른 기계 번호표를 직접 만든다: host pid kind <마지막 갱신 몇 초 전> [<만든 지 몇 초 전, 없으면 갱신 없음>] [<제목 끝, 기본 "note=">]
# → 번호 출력
qat() { local at=$(($(date +%s) - $4)) s id; id="$(($(date +%s) - ${5:-$4}))000-$1-$2"
  s=$(cd "$GR" && GIT_COMMITTER_DATE="@$at +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue host=$1 pid=$2 at=old kind=$3 priority=normal lane=- ${6:-note=}")
  git -C "$GR" push -q origin "$s:refs/wt-queue/main/$id"; echo "$id"; }
qhead() { local s; s=$(cd "$GR" && GIT_COMMITTER_DATE="@$(($(date +%s) - 2400)) +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue-head ticket=$1 at=old")
  git -C "$GR" push -q origin "$s:refs/wt-queue/main/_head"; }
O1=$(qat elsewhere 1 merge 2400); qhead "$O1"
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "40분 된 다른 기계 merge 차례는 넘겨받음" [ "$rc" = 0 ]
check "  └ 경고" has "$out" "경고: 낡은 번호표를 지웁니다(main/$O1)"
check "  └ 낡은 번호표 지워짐" [ -z "$(git ls-remote "$G" "refs/wt-queue/main/$O1")" ]
wql "$(printf '%s\n' "$out" | tail -n 1)"
O2=$(qat elsewhere 1 release 1200 1500)
s=$(date +%s); rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 2 2>&1) || rc=$?
check "20분 된 다른 기계 release는 낡지 않음 → 시간 초과 3" [ "$rc" = 3 ]
check "  └ 2초 이상 기다림" [ $(($(date +%s) - s)) -ge 2 ]
check "  └ 시간 초과 안내" has "$out" "2초 기다렸지만 차례가 오지 않았습니다"
check "  └ 한 번이라도 갱신된 다른 host 번호표는 30분 규칙 그대로" [ -n "$(git ls-remote "$G" "refs/wt-queue/main/$O2")" ]
check "  └ 내 번호표는 지우고 남의 것은 둠" bash -c "[ \"\$(git ls-remote '$G' 'refs/wt-queue/main/*' | cut -f2)\" = 'refs/wt-queue/main/$O2' ]"
git -C "$GR" push -q origin ":refs/wt-queue/main/$O2"
O2=$(qat elsewhere 1 release 2400)
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "release도 30분이 넘으면 넘겨받음(90분 폐지)" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O2)' >/dev/null" _ "$out"
wql "$(printf '%s\n' "$out" | tail -n 1)"
O3=$(qat hx "$DEAD" merge 0)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "같은 host의 끝난 pid라도 갱신이 신선하면 지우지 않음(3)" [ "$rc" = 3 ]
check "  └ 그 번호표 남음" [ -n "$(git ls-remote "$G" "refs/wt-queue/main/$O3")" ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O3"
O3=$(qat hx "$DEAD" merge 10)
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "같은 host의 끝난 pid + 갱신이 주기 3배(6초) 넘게 멈춤 → 넘겨받음" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O3)' >/dev/null" _ "$out"
wql "$(printf '%s\n' "$out" | tail -n 1)"
O4=$(qat elsewhere "$DEAD" merge 0)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "다른 host의 pid는 끝났는지 몰라 넘겨받지 않음(3)" [ "$rc" = 3 ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O4"
# 한 번도 갱신되지 않은 번호표(결과를 모른 채 늦게 반영된 push): 갱신 주기 3배 + 시계 여유(120초)가 지나면 다른 host라도 낡음
O4=$(qat elsewhere 1 merge 200); qhead "$O4"
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "갱신 없는 다른 host 번호표(차례 쥠)는 주기 3배 + 여유 뒤 넘겨받음" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O4)' >/dev/null" _ "$out"
wql "$(printf '%s\n' "$out" | tail -n 1)"
O4=$(qat elsewhere 1 merge 100)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "  └ 여유(주기 3배 + 120초) 안이면 넘겨받지 않음(3)" [ "$rc" = 3 ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O4"
O4=$(qat elsewhere 1 merge 200 300)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "  └ 한 번 갱신된 다른 host 번호표는 같은 나이라도 넘겨받지 않음(3)" [ "$rc" = 3 ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O4"
# 갱신 표식(beat=1): 받자마자 올린 갱신이 있으면 그 뒤 끊겨도(첫 주기 전 와이파이·잠자기) 30분 규칙
O4=$(qat elsewhere 1 merge 200 200 "beat=1 note=")
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "  └ 갱신 표식이 있으면 커밋 시각이 생성 시각과 같아도 넘겨받지 않음(3)" [ "$rc" = 3 ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O4"
O4=$(qat elsewhere 1 merge 200 200 "note=메모 beat=1")
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "  └ 메모 안의 beat=1은 표식이 아님(넘겨받음)" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O4)' >/dev/null" _ "$out"
wq leave "$(printf '%s\n' "$out" | tail -n 1)" || git -C "$GR" push -q origin ":refs/wt-queue/main/$O4" ":refs/wt-queue/main/_head"
sleep 300 & SP3=$!
QR=$(WT_HOST=hb WT_QUEUE_BEAT=20 wq enter merge --pid "$SP3" 2>/dev/null) || true
check "번호표를 받자마자(첫 주기 20초 전) 표식 달린 갱신이 올라감" bash -c "for _ in \$(seq 1 20); do git --git-dir='$G' log -1 --format=%s '$QR' 2>/dev/null | grep -F ' beat=1 note=' >/dev/null && exit 0; sleep 0.5; done; exit 1"
check "  └ 표식이 있어도 목록은 그대로(메모 칸에 표식 없음)" bash -c "printf '%s\n' \"\$1\" | grep -E '^  1\. normal  hb  merge  \(0분째\) \[차례\]  $QR  $' >/dev/null" _ "$(wq 2>&1)"
wql "$QR"; kill "$SP3"; wait "$SP3" 2>/dev/null || true
# 0으로 시작하는 번호(bash 3.2가 8진으로 읽다 셸을 끝냄)
s=$(cd "$GR" && GIT_COMMITTER_DATE="@$(($(date +%s) - 200)) +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue host=zero pid=1 at=old kind=merge priority=normal lane=- note=")
git -C "$GR" push -q origin "$s:refs/wt-queue/main/0999-zero-1"
rc=0; out=$(wq 2>&1) || rc=$?
check "0으로 시작하는 번호도 대기열을 읽음(10진)" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F 'refs/wt-queue/main/0999-zero-1' >/dev/null" _ "$out"
git -C "$GR" push -q origin ":refs/wt-queue/main/0999-zero-1"
check "대기열 비움" qempty
check "origin 없으면 queue 1" bash -c "cd '$T/noorigin' && ! '$WT' queue 2>/dev/null"
check "잘못된 kind 거절" bash -c "! (cd '$GR' && '$WT' queue enter deploy 2>/dev/null)"
check "빈 목록" has "$(wq 2>&1)" "비어 있음"

scene "⑫-5 --pid 필수·갱신 재시도·pid가 끝나면 지움·차례 잃음·옛 판 머지 선점"
qgone() { for _ in $(seq 1 30); do qempty && return 0; sleep 0.5; done; return 1; }
rc=0; (cd "$GR" && exec "$WT" queue enter release >/dev/null 2>&1) || rc=$?
check "--pid 없는 enter는 사용법 오류 2" [ "$rc" = 2 ]
check "  └ 번호표를 만들지 않음" qempty
QR=$(WT_HOST=hb wq enter merge --pid $$ 2>/dev/null)
chmod a-w "$G/refs/wt-queue/main"; sleep 3   # origin 쓰기 실패 동안 갱신 push가 실패한다
ct0=$(git --git-dir="$G" log -1 --format=%ct "$QR")
chmod u+w "$G/refs/wt-queue/main"; sleep 5
check "갱신 push가 실패해도 다음 주기에 다시 시도(갱신 시각이 나아감)" [ "$(git --git-dir="$G" log -1 --format=%ct "$QR")" -gt "$ct0" ]
wql "$QR"
check "leave 뒤 갱신은 스스로 끝나고 번호표를 되살리지 않음" bash -c "sleep 5; [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
sleep 300 & SP=$!
QR=$(WT_HOST=hb wq enter release --pid "$SP" 2>/dev/null)
check "enter 뒤에도 --pid가 살아 있으면 번호표·차례 유지" bash -c "sleep 3; [ -n \"\$(git ls-remote '$G' '$QR')\" ] && [ -n \"\$(git ls-remote '$G' refs/wt-queue/main/_head)\" ]"
kill "$SP"; wait "$SP" 2>/dev/null || true
check "--pid가 끝나면 갱신이 번호표·차례를 지움" qgone
F5=$(gstart f5); echo f5 >"$F5/f5.txt"; commit "$F5" "f5 추가"
rm -f "$T/moved"
rc=0; out=$(cd "$F5" && PATH="$T/bin:$PATH" VERIFY_HOOK="if [ -f '$T/moved' ]; then git --git-dir='$G' update-ref -d refs/wt-queue/main/_head; else touch '$T/moved'; $ELSE; fi" "$WT" finish 2>&1) || rc=$?
git -C "$GR" fetch -q origin
check "차례를 쥔 동안 _head를 잃으면 머지하지 않고 멈춤" bash -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -F '머지 차례를 잃었습니다' >/dev/null" _ "$out"
check "  └ f5는 main에 없음" bash -c "! git -C '$GR' cat-file -e origin/main:f5.txt 2>/dev/null"
check "  └ 번호표 정리" qgone
(cd "$GR" && "$WT" claim merge-main --pid $$ >/dev/null 2>&1)
(cd "$F5" && PATH="$T/bin:$PATH" exec "$WT" finish >"$T/wait.out" 2>&1) & WP=$!
untilf "$T/wait.out" "옛 판 wt의 머지 선점 merge-main"
check "옛 판 머지 선점(refs/wt-claims/merge-main)이 살아 있으면 기다림" has "$(cat "$T/wait.out")" "옛 판 wt의 머지 선점 merge-main 이 살아 있어 풀릴 때까지 기다립니다"
sleep 1; git -C "$GR" fetch -q origin
check "  └ 기다리는 동안 머지하지 않음" bash -c "! git -C '$GR' cat-file -e origin/main:f5.txt 2>/dev/null"
# 옛 판 finish가 선점을 쥔 채 main에 머지한 장면: 풀린 뒤 기준을 다시 받아 다시 올려 검증해야 한다.
runs=$(verify_runs); eval "$ELSE"
(cd "$GR" && "$WT" unclaim merge-main "$(git ls-remote "$G" refs/wt-claims/merge-main | cut -f1)")
rc=0; wait "$WP" || rc=$?
git -C "$GR" fetch -q origin
check "  └ 선점이 풀리면 머지" bash -c "[ $rc = 0 ] && git -C '$GR' cat-file -e origin/main:f5.txt"
check "  └ 기다리는 사이 main이 움직였으면 다시 올려 검증" bash -c "[ \"\$(wc -l <'$VERIFY_LOG' | tr -d ' ')\" = $((runs + 1)) ] && grep -F '검증하는 사이 origin/main이 움직였습니다' '$T/wait.out' >/dev/null"
check "  └ 대기열 비움" qgone
H2=$(gstart h2); echo h2 >"$H2/h2.txt"; commit "$H2" "h2 추가"
(cd "$GR" && "$WT" claim merge-main --pid $$ >/dev/null 2>&1)
(cd "$GR" && PATH="$T/bin:$PATH" exec "$WT" train h2 >"$T/train.out" 2>&1) & WP=$!
untilf "$T/train.out" "옛 판 wt의 머지 선점 merge-main"
eval "$ELSE"
(cd "$GR" && "$WT" unclaim merge-main "$(git ls-remote "$G" refs/wt-claims/merge-main | cut -f1)")
rc=0; wait "$WP" || rc=$?
git -C "$GR" fetch -q origin
check "train: 옛 선점을 기다리는 사이 main이 움직이면 머지하지 않고 멈춤" bash -c "[ $rc = 1 ] && grep -F '검증하는 사이 origin/main이 움직여 머지하지 않았습니다' '$T/train.out' >/dev/null && ! git -C '$GR' cat-file -e origin/main:h2.txt 2>/dev/null"
check "  └ 대기열 비움" qgone

scene "⑫-6 오래 사는 --pid: init·끝난 pid 거절, 갱신 상한, 오래 쥔 차례 표시"
rc=0; (cd "$GR" && exec "$WT" queue enter release --pid 1 >/dev/null 2>&1) || rc=$?
check "--pid 1 거절(2)" bash -c "[ $rc = 2 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
rc=0; (cd "$GR" && exec "$WT" queue enter release --pid "$DEAD" >/dev/null 2>&1) || rc=$?
check "끝난 --pid 거절(2)" [ "$rc" = 2 ]
QR=$(WT_HOST=hb wq enter release --pid $$ --wait 0 --max-hold 1 2>/dev/null)
sleep 5; ct0=$(git --git-dir="$G" log -1 --format=%ct "$QR"); sleep 5
check "--max-hold가 지나면 pid가 살아 있어도 갱신을 멈춤" [ "$(git --git-dir="$G" log -1 --format=%ct "$QR")" = "$ct0" ]
check "  └ 목록에 [갱신 멈춤]" has "$(wq 2>&1)" "[갱신 멈춤"
wql "$QR"
O5=$(qat elsewhere 1 merge 0)
s=$(cd "$GR" && GIT_COMMITTER_DATE="@$(($(date +%s) - 4000)) +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue-head ticket=$O5 at=old")
git -C "$GR" push -q origin "$s:refs/wt-queue/main/_head"
check "1시간 넘게 쥔 차례 표시" has "$(wq 2>&1)" "[차례 66분째 쥠 — 오래 쥔 차례]"
git -C "$GR" push -q origin ":refs/wt-queue/main/_head" ":refs/wt-queue/main/$O5"
check "  └ 대기열 비움" qgone

scene "⑫-6b 놓기 실패(네트워크 끊김): 갱신은 멈추고 백그라운드가 다시 지움 — 남의 번호표·차례·다른 sha는 건드리지 않음"
# 끊김 흉내 git: $T/nopush가 있으면 push만 실패(읽기는 됨), $T/lostack이 있으면 push는 올라가는데 실패로 보이고 ls-remote도 실패,
# $T/lateack이 있으면 push는 실패로 보이고 $T/land가 생긴 뒤에야 서버에 반영된다. $T/lslog가 있으면 끝난 ls-remote마다 한 줄 남긴다.
mkdir -p "$T/gitfail"
cat >"$T/gitfail/git" <<GITFAIL
#!/usr/bin/env bash
[ "\${1-}" = push ] && [ -f "$T/nopush" ] && exit 1
[ "\${1-}" = push ] && [ -f "$T/lateack" ] && { (i=0; until [ -f "$T/land" ]; do i=\$((i + 1)); [ \$i -le 600 ] || exit 1; sleep 0.1; done; "$(command -v git)" "\$@"; touch "$T/landed") </dev/null >/dev/null 2>&1 & exit 1; }
# $T/droplog가 있으면 q_drop 임시 ref 이름의 pid가 부른 셸(PPID) 자신인지 남긴다(ok / bad <이름 pid> <PPID>)
if [ "\${1-}" = fetch ] && [ -f "$T/droplog" ]; then case "\$*" in *refs/wt-queue-drop/*) n="\$*"; n=\${n##*refs/wt-queue-drop/}; n=\${n%%-*}
  if [ "\$n" = "\$PPID" ]; then echo ok >>"$T/droplog"; else echo "bad \$n \$PPID" >>"$T/droplog"; fi ;; esac; fi
[ "\${1-}" = ls-remote ] && [ -f "$T/lslog" ] && { "$(command -v git)" "\$@"; r=\$?; echo x >>"$T/lslog"; exit \$r; }
[ "\${1-}" = push ] && [ -f "$T/lostack" ] && { "$(command -v git)" "\$@"; exit 1; }
[ "\${1-}" = ls-remote ] && [ -f "$T/lostack" ] && exit 1
exec "$(command -v git)" "\$@"
GITFAIL
chmod +x "$T/gitfail/git"
wqf() { (cd "$GR" && PATH="$T/gitfail:$T/bin:$PATH" exec "$WT" queue "$@"); }
qref() { git ls-remote "$G" "$1" | cut -f1; }
# 그 인자로 띄운 wt(정리 프로세스 포함)가 남아 있는지
wtproc() { ps -A -o args= | grep -F -- "queue enter $1" | grep -v grep >/dev/null; }
nowtproc() { for _ in 1 2 3 4 5 6; do wtproc "$1" || return 0; sleep 0.5; done; return 1; }
qgone_ref() { for _ in $(seq 1 30); do [ -z "$(qref "$1")" ] && return 0; sleep 0.5; done; return 1; }
sleep 300 & SP=$!
O6=$(qat elsewhere 1 merge 0)
# 명령 치환으로 부른다: 시간 초과로 끝날 때 정리 프로세스가 남아도 부른 쪽은 기다리지 않아야 한다
(s=$(date +%s); rc=0; out=$(WT_HOST=hb wqf enter merge --pid "$SP" --wait 7 2>&1) || rc=$?
 echo "$rc $(($(date +%s) - s))" >"$T/rc6"; printf '%s\n' "$out" >"$T/err6") & WP=$!
qwait_n 2; touch "$T/nopush"; wait "$WP" || true
MY=$(git ls-remote "$G" 'refs/wt-queue/main/*' | cut -f2 | grep -v "/$O6\$")
read -r rc6 el6 <"$T/rc6"
check "시간 초과(3) 때 놓기 실패 → 오래 사는 --pid의 번호표가 남음" bash -c "[ '$rc6' = 3 ] && [ -n '$MY' ] && [ -n \"\$(git ls-remote '$G' '$MY')\" ]"
check "  └ 백그라운드 정리 프로세스가 돌고 있음" wtproc "merge --pid $SP --wait 7"
check "  └ 명령 치환이 정리 프로세스를 기다리지 않음(7초 기다림 + 여유 5초 안)" [ "$el6" -le 12 ]
check "  └ 경고가 보임" grep -F "백그라운드에서 다시 지웁니다" "$T/err6"
rm -f "$T/nopush"
check "  └ 연결이 돌아오면 백그라운드가 지움(--pid는 아직 살아 있음)" qgone_ref "$MY"
check "  └ 남의 번호표는 그대로" [ -n "$(qref "refs/wt-queue/main/$O6")" ]
sleep 3
check "  └ 지운 뒤 되살아나지 않음" [ -z "$(qref "$MY")" ]
check "  └ 정리 프로세스도 끝남" nowtproc "merge --pid $SP --wait 7"
# 그사이 남이 내 번호표를 지우고 다른 번호표가 차례를 쥐었으면 아무것도 지우지 않고 끝난다
(WT_HOST=hb wqf enter merge --pid "$SP" --wait 4 >/dev/null 2>&1) & WP=$!
qwait_n 2; touch "$T/nopush"; wait "$WP" || true
MY=$(git ls-remote "$G" 'refs/wt-queue/main/*' | cut -f2 | grep -v "/$O6\$")
git -C "$GR" push -q origin ":$MY"; qhead "$O6"; H6=$(qref refs/wt-queue/main/_head)
rm -f "$T/nopush"; sleep 3
check "남이 지운 뒤 남의 번호표·차례(_head)는 그대로" bash -c "[ -n \"\$(git ls-remote '$G' 'refs/wt-queue/main/$O6')\" ] && [ \"\$(git ls-remote '$G' refs/wt-queue/main/_head | cut -f1)\" = '$H6' ]"
check "  └ 정리 프로세스는 끝남" nowtproc "merge --pid $SP --wait 4"
git -C "$GR" push -q origin ":refs/wt-queue/main/_head" ":refs/wt-queue/main/$O6"
check "  └ 대기열 비움" qgone
# 상한(WT_QUEUE_REAP)이 지나면 끝난다 — 그 뒤는 30분 낡음 판정이 맡는다
O6=$(qat elsewhere 1 merge 0)
(WT_HOST=hb WT_QUEUE_REAP=2 wqf enter merge --pid "$SP" --wait 5 >/dev/null 2>&1) & WP=$!
qwait_n 2; touch "$T/nopush"; wait "$WP" || true
MY=$(git ls-remote "$G" 'refs/wt-queue/main/*' | cut -f2 | grep -v "/$O6\$")
sleep 5; rm -f "$T/nopush"; sleep 3
check "상한이 지나면 다시 지우지 않고 끝남" bash -c "[ -n \"\$(git ls-remote '$G' '$MY')\" ]"
check "  └ 정리 프로세스 끝남" nowtproc "merge --pid $SP --wait 5"
check "  └ 갱신도 멈춰 번호표가 다시 올라가지 않음" [ "$(git --git-dir="$G" log -1 --format=%ct "$MY")" -le "$(($(date +%s) - 7))" ]
git -C "$GR" push -q origin ":$MY" ":refs/wt-queue/main/$O6"
# enter 뒤 --pid가 끝났는데 갱신의 놓기가 실패: 갱신이 다시 지우는 쪽으로 넘어간다(번호표·_head 모두)
sleep 300 & SP2=$!
QR=$(WT_HOST=hb wqf enter release --pid "$SP2" 2>/dev/null)
touch "$T/nopush"; kill "$SP2"; wait "$SP2" 2>/dev/null || true; sleep 4
check "--pid가 끝날 때 놓기 실패 → 번호표·차례 남음" bash -c "[ -n \"\$(git ls-remote '$G' '$QR')\" ] && [ -n \"\$(git ls-remote '$G' refs/wt-queue/main/_head)\" ]"
rm -f "$T/nopush"
check "  └ 연결이 돌아오면 번호표·차례 지움" qgone
# 같은 장면에서 번호표가 다른 sha로 바뀌었으면(lease 어긋남) 건드리지 않는다
sleep 300 & SP2=$!
QR=$(WT_HOST=hb wqf enter release --pid "$SP2" 2>/dev/null)
touch "$T/nopush"; kill "$SP2"; wait "$SP2" 2>/dev/null || true; sleep 4
s=$(cd "$GR" && git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue host=hb pid=1 at=x kind=release priority=release lane=- note=다른 sha")
git -C "$GR" push -q -f origin "$s:$QR"; H6=$(qref refs/wt-queue/main/_head)
rm -f "$T/nopush"; sleep 3
check "다른 sha로 바뀐 번호표와 그 차례는 그대로" bash -c "[ \"\$(git ls-remote '$G' '$QR' | cut -f1)\" = '$s' ] && [ \"\$(git ls-remote '$G' refs/wt-queue/main/_head | cut -f1)\" = '$H6' ]"
git -C "$GR" push -q origin ":$QR" ":refs/wt-queue/main/_head"
# 갱신 push가 올라갔는데 실패로 보이고 다시 보기도 실패한 뒤 --pid가 끝나면: 올라간 sha도 내 것으로 보고 지운다
sleep 300 & SP2=$!
QR=$(WT_HOST=hb wqf enter release --pid "$SP2" 2>/dev/null); s0=$(qref "$QR")
touch "$T/lostack"; sleep 3; kill "$SP2"; wait "$SP2" 2>/dev/null || true; sleep 3
check "갱신 결과를 모르는 사이 --pid 끝남 → 번호표는 새 sha로 남아 있음" bash -c "[ -n \"\$(git ls-remote '$G' '$QR')\" ] && [ \"\$(git ls-remote '$G' '$QR' | cut -f1)\" != '$s0' ]"
rm -f "$T/lostack"
check "  └ 연결이 돌아오면 번호표·차례 지움" qgone
# 번호표 push가 서버에는 들어갔는데 실패로 보이면: enter는 1, 백그라운드가 그 번호표를 지운다
touch "$T/lostack"; rc=0; WT_HOST=hb wqf enter release --pid "$SP" >/dev/null 2>&1 || rc=$?
check "번호표 push 결과를 모르면 enter 1, 번호표는 남아 있음" bash -c "[ $rc = 1 ] && [ -n \"\$(git ls-remote '$G' 'refs/wt-queue/main/*')\" ]"
rm -f "$T/lostack"
check "  └ 연결이 돌아오면 그 번호표 지움" qgone
# 부른 쪽 작업 폴더(워크트리)가 지워져도 갱신은 git 공용 폴더에서 돌아 --pid가 끝나면 지운다
git -C "$GR" worktree add -q --detach "$T/qwt" 2>/dev/null
sleep 300 & SP2=$!
QR=$(cd "$T/qwt" && WT_HOST=hb PATH="$T/bin:$PATH" "$WT" queue enter release --pid "$SP2" 2>/dev/null)
git -C "$GR" worktree remove --force "$T/qwt"
kill "$SP2"; wait "$SP2" 2>/dev/null || true
check "부른 워크트리에서 enter 성공" [ -n "$QR" ]
check "  └ 그 워크트리가 지워진 뒤 --pid가 끝나도 번호표·차례 지움" qgone
# wt queue leave도 실패하면 1로 끝나되 백그라운드가 마저 지운다
QR=$(WT_HOST=hb wq enter release --pid "$SP" 2>/dev/null)
touch "$T/nopush"; rc=0; wqf leave "$QR" >/dev/null 2>&1 || rc=$?
check "leave 실패는 1, 번호표 남음" bash -c "[ $rc = 1 ] && [ -n \"\$(git ls-remote '$G' '$QR')\" ]"
rm -f "$T/nopush"
check "  └ 연결이 돌아오면 번호표·차례 지움" qgone
# 번호표 push가 실패로 보였는데 서버 반영이 정리 프로세스의 첫 조회보다 늦으면: 빈 결과를 더 보다가 늦게 들어온 번호표를 지운다
rm -f "$T/land" "$T/landed"; : >"$T/lslog"; touch "$T/lateack"
rc=0; WT_HOST=hb WT_QUEUE_LATE=30 wqf enter release --pid "$SP" >/dev/null 2>&1 || rc=$?
rm -f "$T/lateack"
for _ in $(seq 1 300); do [ -s "$T/lslog" ] && break; sleep 0.1; done
touch "$T/land"
check "늦게 반영된 번호표 push: enter 1, 정리 프로세스가 반영 전에 한 번 조회함" bash -c "[ $rc = 1 ] && [ -s '$T/lslog' ]"
check "  └ 첫 조회 뒤에 반영된 번호표도 지움" bash -c "for _ in \$(seq 1 60); do [ -f '$T/landed' ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ] && exit 0; sleep 0.5; done; exit 1"
rm -f "$T/lslog" "$T/land" "$T/landed"
# 부른 쪽이 상대 경로 GIT_DIR(git 훅 안 등)를 주어도 갱신·정리는 git 공용 폴더에서 git을 찾는다
sleep 300 & SP2=$!
QR=$(cd "$GR" && GIT_DIR=.git WT_HOST=hb PATH="$T/bin:$PATH" "$WT" queue enter release --pid "$SP2" 2>/dev/null)
kill "$SP2"; wait "$SP2" 2>/dev/null || true
check "상대 경로 GIT_DIR=.git으로 enter 성공" [ -n "$QR" ]
check "  └ --pid가 끝나면 갱신이 번호표·차례 지움" qgone
QR=$(WT_HOST=hb wq enter release --pid "$SP" 2>/dev/null)
touch "$T/nopush"; rc=0; (cd "$GR" && GIT_DIR=.git PATH="$T/gitfail:$T/bin:$PATH" exec "$WT" queue leave "$QR") >/dev/null 2>&1 || rc=$?
rm -f "$T/nopush"
check "상대 경로 GIT_DIR=.git으로 부른 leave가 실패해도 백그라운드가 지움" bash -c "[ $rc = 1 ]"
check "  └ 번호표·차례 지움" qgone
# 갱신은 부른 쪽이 연 fd를 물려받지 않는다 — 명령 치환 파이프를 fd 3·200으로 넘기면 물려받은 갱신이 --pid가 끝날 때까지 붙든다
for fd in 3 200; do
  sleep 30 & SP2=$!
  s=$(date +%s); QR=$(cd "$GR" && export WT_HOST=hb PATH="$T/bin:$PATH" && eval "\"\$WT\" queue enter release --pid $SP2 $fd>&1 >/dev/null 2>&1"); el=$(($(date +%s) - s))
  check "갱신이 부른 쪽 fd ${fd}를 물려받지 않음(명령 치환이 --pid(30초)보다 먼저 끝남)" [ "$el" -le 15 ]
  kill "$SP2" 2>/dev/null; wait "$SP2" 2>/dev/null || true
  check "  └ 번호표·차례 지움" qgone
done
# 백그라운드 정리의 q_drop 임시 ref 이름은 부모 pid가 아니라 자기 pid — 부모가 끝난 뒤 다른 wt의 청소가 쓰는 중인 ref를 지우지 않게
sleep 300 & SP2=$!
QR=$(WT_HOST=hb wqf enter release --pid "$SP2" 2>/dev/null)
: >"$T/droplog"; kill "$SP2"; wait "$SP2" 2>/dev/null || true
check "--pid가 끝나 갱신이 번호표·차례 지움" qgone
out=$(cat "$T/droplog"); rm -f "$T/droplog"
check "  └ 그 q_drop 임시 ref 이름의 pid가 갱신 프로세스 자신" bash -c "printf '%s\n' \"\$1\" | grep -x ok >/dev/null && ! printf '%s\n' \"\$1\" | grep bad >/dev/null" _ "$out"
# q_drop이 fetch와 지우기 사이에 죽어 남긴 임시 ref: pid가 끝났으면 q_scan이 치운다
git -C "$GR" update-ref "refs/wt-queue-drop/$DEAD-1" HEAD; git -C "$GR" update-ref "refs/wt-queue-drop/$$-1" HEAD
wq >/dev/null 2>&1
check "끝난 pid의 임시 ref(refs/wt-queue-drop/)는 q_scan이 치움" [ -z "$(git -C "$GR" for-each-ref "refs/wt-queue-drop/$DEAD-1")" ]
check "  └ 살아 있는 pid의 것은 둠" [ -n "$(git -C "$GR" for-each-ref "refs/wt-queue-drop/$$-1")" ]
git -C "$GR" update-ref -d "refs/wt-queue-drop/$$-1"
kill "$SP"; wait "$SP" 2>/dev/null || true

scene "⑫-7 기계 간 같은 이름 레인: start 거부·finish가 남의 브랜치를 덮어쓰지 않음"
OC="$T/othermachine"; git clone -q "$G" "$OC"
opush() { (cd "$OC" && git fetch -q origin && git checkout -q -B "$1" origin/main && echo "$2" >"$2.txt" && git add -A && git commit -qm "$2" && git push -q -f origin "$1"); }
opush wt/dup dup-o
rc=0; out=$(cd "$GR" && "$WT" start dup 2>&1) || rc=$?
check "(a) 원격에 같은 wt/<슬러그>가 있으면 start 거부" bash -c "[ $rc = 1 ] && [ ! -e '$GR.wt/dup' ] && ! git -C '$GR' show-ref --verify --quiet refs/heads/wt/dup"
check "  └ 다른 기계 안내" has "$out" "다른 기계"
B7=$(gstart b7); echo mine >"$B7/b7.txt"; commit "$B7" "b7 mine"
opush wt/b7 b7-o; THEIRS=$(git --git-dir="$G" rev-parse refs/heads/wt/b7)
git -C "$GR" fetch -q origin   # 이 기계가 남의 브랜치를 받아 둔 상태 — 기대값 없는 lease면 그것을 기대값으로 덮어쓴다
rc=0; out=$(cd "$B7" && PATH="$T/bin:$PATH" "$WT" finish 2>&1) || rc=$?
check "(b) 남의 같은 이름 브랜치가 있으면 finish 중단·덮어쓰지 않음" bash -c "[ $rc = 1 ] && [ \"\$(git --git-dir='$G' rev-parse refs/heads/wt/b7)\" = '$THEIRS' ] && [ -d '$B7' ]"
check "  └ main에 안 들어감" bash -c "! git --git-dir='$G' cat-file -e main:b7.txt 2>/dev/null"
check "  └ 이름을 바꿔 다시 시작 안내" has "$out" "새 이름으로 wt start"
check "  └ 대기열 비움" qgone
C7=$(gstart c7); echo c7 >"$C7/c7.txt"; commit "$C7" "c7 추가"
rc=0; (cd "$C7" && PATH="$T/bin:$PATH" GH_FAIL_MERGE=1 "$WT" finish >/dev/null 2>&1) || rc=$?
check "(c) 첫 finish는 머지 실패로 멈추고 레인 브랜치는 원격에 남음" bash -c "[ $rc = 1 ] && git --git-dir='$G' rev-parse --verify --quiet refs/heads/wt/c7 >/dev/null"
opush main m7   # 기준이 움직여 다음 finish가 rebase한다 → 원격 레인 브랜치는 HEAD의 조상이 아니다
rc=0; out=$(cd "$C7" && PATH="$T/bin:$PATH" "$WT" finish 2>&1) || rc=$?
git -C "$GR" fetch -q origin
check "(c) rebase 뒤 다시 finish하면 내가 올린 sha를 기대값으로 재푸시·머지" bash -c "[ $rc = 0 ] && git -C '$GR' cat-file -e origin/main:c7.txt && git -C '$GR' cat-file -e origin/main:m7.txt"
opush wt/d7 d7-o; git -C "$GR" fetch -q origin
git --git-dir="$G" update-ref -d refs/heads/wt/d7   # 다른 기계가 끝내고 지웠고, 이 기계에는 낡은 origin/wt/d7이 남음
D7=$(gstart d7); echo d7 >"$D7/d7.txt"; commit "$D7" "d7 추가"
rc=0; out=$(cd "$D7" && PATH="$T/bin:$PATH" "$WT" finish 2>&1) || rc=$?
git -C "$GR" fetch -q origin
check "(d) 원격 브랜치가 없으면(낡은 추적 ref가 있어도) 첫 push·머지" bash -c "[ $rc = 0 ] && git -C '$GR' cat-file -e origin/main:d7.txt"
git -C "$OC" remote set-url origin "$T/nowhere.git"
rc=0; out=$(cd "$OC" && "$WT" start off 2>&1) || rc=$?
check "origin을 못 보면(오프라인) 경고만 하고 start 진행" bash -c "[ $rc = 0 ] && [ -d '$OC.wt/off' ]"
check "  └ 경고" has "$out" "확인하지 못했습니다"
git --git-dir="$G" update-ref -d refs/heads/wt/dup; git --git-dir="$G" update-ref -d refs/heads/wt/b7
git -C "$GR" worktree remove --force "$B7"; git -C "$GR" branch -q -D wt/b7

scene "⑦ gc의 24시간 판정은 status가 건드리는 파일을 사용 흔적으로 안 본다"
OLD=$(start gc-old); FRESH=$(start gc-fresh)
OGD=$(git -C "$OLD" rev-parse --absolute-git-dir)
find "$OGD" "$OLD" -exec touch -h -t 202001010000 {} + 2>/dev/null
git -C "$OLD" status >/dev/null; git -C "$OLD" status --porcelain >/dev/null   # gd mtime·index를 지금으로 갱신
out=$("$WT" gc 2>&1)
check "오래된 레인은 status 뒤에도 정리 대상" has "$out" "정리 대상 워크트리 $OLD"
check "방금 만든 레인은 24시간 내 사용으로 유지" has "$out" "유지(24시간 내 사용) $FRESH"
git -C "$R" worktree remove --force "$FRESH" 2>/dev/null || true; git -C "$R" branch -D wt/gc-fresh >/dev/null 2>&1 || true

scene "⑧ .claude/wt-teardown.sh: 워크트리를 지우기 직전에 그 안에서 실행, 실패해도 정리는 계속"
TD_LOG="$T/teardown.log"; : >"$TD_LOG"; export TD_LOG
(cd "$R" && git pull -q --ff-only origin main \
  && printf '#!/usr/bin/env bash\necho "$PWD|$WT_MAIN" >>"$TD_LOG"\n[ -z "${TEARDOWN_FAIL-}" ]\n' >.claude/wt-teardown.sh \
  && chmod +x .claude/wt-teardown.sh && git add -A && git commit -qm teardown && git push -q origin main)
OLDBASE=$(git -C "$R" rev-parse HEAD~1); git -C "$R" branch -q -f td-old "$OLDBASE"   # 정리 스크립트가 없던 기준
TD1=$(start td-one); echo x >"$TD1/td1.txt"; commit "$TD1" "td1"
(cd "$TD1" && "$WT" finish >/dev/null 2>&1) || true
check "finish가 지우기 전에 그 워크트리 안에서 실행(WT_MAIN=메인 폴더)" has "$(cat "$TD_LOG")" "$TD1|$R"
check "  └ 레인은 지워짐" [ ! -e "$TD1" ]
TD2=$(start td-two); echo y >"$TD2/td2.txt"; commit "$TD2" "td2"
rc=0; out=$(cd "$TD2" && TEARDOWN_FAIL=1 "$WT" finish 2>&1) || rc=$?
check "정리 스크립트가 실패해도 finish 성공·레인 삭제" bash -c "[ $rc = 0 ] && [ ! -e '$TD2' ]"
check "  └ 경고" has "$out" "wt-teardown.sh 실패"
TD3=$(start td-old --base td-old)   # 워크트리에는 스크립트가 없다 → 메인 폴더 것을 쓴다
find "$(git -C "$TD3" rev-parse --absolute-git-dir)" "$TD3" -exec touch -h -t 202001010000 {} + 2>/dev/null
out=$("$WT" gc --apply 2>&1)
check "gc --apply도 지우기 전에 실행(스크립트 없는 레인은 메인 폴더 것)" bash -c "[ ! -e '$TD3' ] && grep -F '$TD3|$R' '$TD_LOG' >/dev/null"
git -C "$R" branch -q -D td-old 2>/dev/null || true   # 레인이 지워지면 기준이 아니게 돼 gc가 이미 지웠을 수 있다

scene "⑬ git 위치 환경(GIT_DIR 등, git 훅 안에서 부른 경우): 시작 때 절대 위치로 옮기고 지워 맞는 저장소·워크트리를 다룸"
E1=$(start env-rel); echo e1 >"$E1/e1.txt"; commit "$E1" "env e1"; mkdir -p "$E1/sub"
rc=0; out=$(cd "$E1/sub" && GIT_DIR="../../../$(basename "$R")/.git/worktrees/env-rel" "$WT" finish 2>&1) || rc=$?
git -C "$R" fetch -q origin
check "상대 GIT_DIR(하위 폴더에서 워크트리 git 폴더)로 finish 머지·정리" bash -c "[ $rc = 0 ] && git -C '$R' cat-file -e origin/main:e1.txt && [ ! -e '$E1' ]"
E2=$(start env-wt); echo e2 >"$E2/e2.txt"; commit "$E2" "env e2"
rc=0; out=$(cd "$T" && GIT_DIR="$R/.git/worktrees/env-wt" GIT_WORK_TREE="$E2" "$WT" finish 2>&1) || rc=$?
git -C "$R" fetch -q origin
check "GIT_DIR + GIT_WORK_TREE(저장소 밖에서)로 finish 머지·정리" bash -c "[ $rc = 0 ] && git -C '$R' cat-file -e origin/main:e2.txt && [ ! -e '$E2' ] && ! git -C '$R' show-ref --verify --quiet refs/heads/wt/env-wt"
E3=$(start env-gd); runs=$(verify_runs)
rc=0; out=$(cd "$T" && GIT_DIR="$R/.git/worktrees/env-gd" "$WT" verify 2>&1) || rc=$?
check "워크트리 git 폴더 GIT_DIR만으로(저장소 밖에서) verify가 그 워크트리를 검증" bash -c "[ $rc = 0 ] && [ \"\$(wc -l <'$VERIFY_LOG' | tr -d ' ')\" = $((runs + 1)) ]"
check "  └ 검증 기록이 그 워크트리 git 폴더에" [ -s "$R/.git/worktrees/env-gd/wt-verified" ]
out=$(cd "$E3" && GIT_DIR=../../$(basename "$R")/.git "$WT" list 2>&1) || true
check "메인 .git을 가리키는 상대 GIT_DIR로 list(다른 워크트리 위치에서)" has "$out" "$E3  wt/env-gd"
rc=0; out=$(cd "$T" && GIT_DIR="$T/origin.git" "$WT" list 2>&1) || rc=$?
check "bare 저장소 GIT_DIR로 list" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '기준: main' >/dev/null" _ "$out"
rc=0; out=$(cd "$T" && GIT_DIR="$T/nowhere.git" "$WT" list 2>&1) || rc=$?
check "저장소를 못 찾으면 오류" [ "$rc" != 0 ]
git -C "$R" worktree remove --force "$E3"; git -C "$R" branch -q -D wt/env-gd
# 시작 때 옮겨 간 폴더: wt 머리(맨 위 ~ 정리 트랩 앞)만 돌려 pwd를 본다. wtcwd <부를 폴더> <환경…>
wtcwd() { local d=$1; shift; (cd "$d" && env "$@" bash -c 'eval "$(sed -n "2,/^# 끝날 때(die/p" "$0")"; pwd -P' "$WT"); }
NB="$T/nobare"; git init -q -b main "$NB"; git -C "$NB" commit -q --allow-empty -m i; git -C "$NB" config --unset core.bare
check "core.bare 없는 일반 저장소 .git은 부모로 옮김(.git 안 아님)" [ "$(wtcwd "$T" GIT_DIR="$NB/.git")" = "$NB" ]
check "bare 저장소는 그 폴더로" [ "$(wtcwd "$T" GIT_DIR="$T/origin.git")" = "$T/origin.git" ]
rc=0; out=$(cd "$NB" && GIT_DIR="$R/.git" "$WT" list 2>&1) || rc=$?
check "작업 폴더가 GIT_DIR과 다른 저장소 안이면 옮기지 않고 멈춤" bash -c "[ $rc != 0 ] && printf '%s' \"\$1\" | grep -F '다른 저장소 안' >/dev/null" _ "$out"
git -C "$NB" worktree add -q -b nested "$NB/nested"
rc=0; out=$(cd "$NB/nested" && GIT_DIR="$NB/.git" "$WT" list 2>&1) || rc=$?
check "그 워크트리 안의 중첩 워크트리에서 부르면 맨 위로 옮김" bash -c "[ $rc = 0 ] && [ '$(wtcwd "$NB/nested" GIT_DIR="$NB/.git")' = '$NB' ]"
git -C "$NB" worktree add -q --relative-paths -b relwt "$T/nobare-rel" 2>/dev/null \
  || { git -C "$NB" worktree add -q -b relwt "$T/nobare-rel"; printf '../../../../nobare-rel/.git\n' >"$NB/.git/worktrees/nobare-rel/gitdir"; }   # --relative-paths 없는 git: 흉내
check "  (상대 gitdir 파일)" bash -c "! grep -q '^/' '$NB/.git/worktrees/nobare-rel/gitdir'"
out=$(cd "$T" && GIT_DIR="$NB/.git/worktrees/nobare-rel" "$WT" claim 2>&1) || true
check "상대 경로 gitdir 파일의 워크트리 git 폴더 GIT_DIR로 claim이 그 워크트리를 맡음" has "$out" "이 세션이 $T/nobare-rel 를 맡습니다"
SUP="$T/super"; git init -q -b main "$T/subsrc"; git -C "$T/subsrc" commit -q --allow-empty -m s
git init -q -b main "$SUP"; (cd "$SUP" && git -c protocol.file.allow=always submodule add -q "$T/subsrc" sm >/dev/null 2>&1 && git commit -qm sm)
check "하위 모듈 git 폴더(core.worktree) GIT_DIR이면 그 작업 폴더로" [ "$(wtcwd "$T" GIT_DIR="$SUP/.git/modules/sm")" = "$SUP/sm" ]

scene "⑭ 준비됨(wt ready) + 묶음 머지(wt flush): 두 기계 흉내, 검증 한 번으로 둘 다 머지"
GR2="$T/ghrepo2"; git clone -q "$G" "$GR2" 2>/dev/null; git -C "$GR2" remote set-head origin main
H1=$(hostname -s)
# wtg <폴더> <host> <wt 인자…>: GitHub 흉내(gh 스텁)로 그 폴더에서 그 host인 척 wt 실행
wtg() { local d=$1 h=$2; shift 2; (cd "$d" && WT_HOST=$h PATH="$T/bin:$PATH" exec "$WT" "$@"); }
gs2() { wtg "$GR2" m2 start "$1" 2>/dev/null | tail -n 1; }
rdy() { git ls-remote "$G" 'refs/wt-ready/*' | wc -l | tr -d ' '; }
rsubj() { git -C "$GR" fetch -q origin "+$1:refs/tmp-rs" && git -C "$GR" log -1 --format=%s refs/tmp-rs && git -C "$GR" update-ref -d refs/tmp-rs; }
mainhas() { git -C "$GR" fetch -q origin && for f; do git -C "$GR" cat-file -e "origin/main:$f" || return 1; done; }
mainlacks() { git -C "$GR" fetch -q origin && ! git -C "$GR" cat-file -e "origin/main:$1" 2>/dev/null; }
git -C "$GR" fetch -q origin; GB=$(git -C "$GR" rev-parse origin/main)
P1=$(gstart p1); echo p1 >"$P1/p1.txt"; commit "$P1" "p1 추가"
P2=$(gs2 p2); echo p2 >"$P2/p2.txt"; commit "$P2" "p2 추가"
echo dirty >"$P1/dirty.txt"
check "미커밋이면 ready 거절" bash -c "! (cd '$P1' && PATH='$T/bin:$PATH' '$WT' ready) 2>/dev/null"
rm "$P1/dirty.txt"
runs=$(verify_runs)
rc=0; out=$(wtg "$P1" "$H1" ready --note "급하지 않음" 2>&1) || rc=$?
check "ready 성공 + 검증 1회" bash -c "[ $rc = 0 ] && [ $(verify_runs) = $((runs + 1)) ]"
check "  └ 원격 레인 브랜치도 올림" [ -n "$(git ls-remote "$G" refs/heads/wt/p1)" ]
wtg "$P2" m2 ready >/dev/null 2>&1
check "두 기계의 표식 둘" [ "$(rdy)" = 2 ]
check "표식의 부모가 레인 커밋" [ "$(git -C "$GR" fetch -q origin refs/wt-ready/main/p1 && git -C "$GR" rev-parse FETCH_HEAD^)" = "$(git -C "$P1" rev-parse HEAD)" ]
check "표식 제목(branch·host·state·note)" bash -c 'printf "%s" "$1" | grep -E "^wt-ready branch=wt/p2 base=main host=m2 .* state=ready note=$" >/dev/null' _ "$(rsubj refs/wt-ready/main/p2)"
out=$(wq 2>&1)
check "wt queue에 준비됨 둘(슬러그·host·나이·메모)" bash -c "printf '%s\n' \"\$1\" | grep -Fx '  main/p1  $H1  0분 전  급하지 않음' >/dev/null && printf '%s\n' \"\$1\" | grep -F '  main/p2  m2  0분 전' >/dev/null" _ "$out"
check "wt list에 준비됨(origin)" has "$(cd "$GR" && "$WT" list 2>&1)" "  main/p2  m2  0분 전"
check "WT_NO_READY=1이면 list가 읽지 않음" hasnt "$(cd "$GR" && WT_NO_READY=1 "$WT" list 2>&1)" "main/p2"
runs=$(verify_runs); : >"$GS/calls"
rc=0; out=$(wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "flush 0" [ "$rc" = 0 ]
check "  └ 검증 한 번" [ "$(verify_runs)" = $((runs + 1)) ]
check "  └ 두 레인 main에" mainhas p1.txt p2.txt
check "  └ 레인마다 커밋 하나(2)" [ "$(git -C "$GR" rev-list --count "$GB..origin/main")" = 2 ]
check "  └ rebase 머지 + --match-head-commit" has "$(cat "$GS/calls")" "--rebase --match-head-commit"
check "  └ 표식 비움" [ "$(rdy)" = 0 ]
check "  └ 원격 레인 브랜치·묶음 브랜치 지움" bash -c "[ -z \"\$(git --git-dir='$G' for-each-ref refs/heads/wt/)\" ]"
check "  └ 번호표 비움" qempty
check "  └ 워크트리는 그대로(다른 기계 것은 건드리지 않음)" bash -c "[ -d '$P1' ] && [ -d '$P2' ]"
check "  └ 메인 폴더 fast-forward" [ -f "$GR/p2.txt" ]
rc=0; out=$(wtg "$P1" "$H1" finish 2>&1) || rc=$?
check "주인 기계의 finish는 '이미 반영됨'으로 정리만" bash -c "[ $rc = 0 ] && [ ! -e '$P1' ]"
check "  └ 안내" has "$out" "이미 main에 반영된 레인입니다"
git -C "$GR2" fetch -q origin
check "다른 기계 list는 [main에 반영됨]" has "$(cd "$GR2" && WT_NO_READY=1 "$WT" list 2>&1)" "wt/p2  +1 [main에 반영됨]"
wtg "$P2" m2 finish >/dev/null 2>&1 || true
check "  └ 그 기계의 finish로 정리" [ ! -e "$P2" ]
Z1=$(gstart z1); echo z >"$Z1/z1.txt"; commit "$Z1" "z1"; wtg "$Z1" "$H1" ready >/dev/null 2>&1
runs=$(verify_runs); rc=0; out=$(wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "레인 하나·기준 그대로면 이미 검증한 트리라 검증 건너뜀" bash -c "[ $rc = 0 ] && [ $(verify_runs) = $runs ]"
check "  └ 안내" has "$out" "이미 검증한 트리와 같아 검증을 건너뜁니다"
wtg "$Z1" "$H1" finish >/dev/null 2>&1 || true
rc=0; out=$(wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "준비된 레인이 없으면 flush 0 + 안내(번호표 없이)" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '준비된 레인이 없습니다' >/dev/null" _ "$out"

scene "⑭-2 묶음에서 충돌하는 레인은 빼고 나머지만 머지, 그 표식에 충돌·기준을 남김"
C1=$(gstart c1); sed -i.bak '3s/.*/C1/' "$C1/a.txt"; rm "$C1/a.txt.bak"; commit "$C1" "c1: 3번 줄"
C2=$(gs2 c2); sed -i.bak '3s/.*/C2/' "$C2/a.txt"; rm "$C2/a.txt.bak"; commit "$C2" "c2: 같은 줄"
wtg "$C1" "$H1" ready >/dev/null 2>&1; wtg "$C2" m2 ready >/dev/null 2>&1
git -C "$GR" fetch -q origin; GB=$(git -C "$GR" rev-parse origin/main)
rc=0; out=$(wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "충돌로 뺀 레인이 있으면 flush 3" [ "$rc" = 3 ]
check "  └ c1만 main에" bash -c "git -C '$GR' fetch -q origin && [ \"\$(git -C '$GR' show origin/main:a.txt | sed -n 3p)\" = C1 ]"
check "  └ 안내" has "$out" "충돌로 뺌: wt/c2"
check "  └ c2 표식: state=conflict + 그때 기준" has "$(rsubj refs/wt-ready/main/c2)" "state=conflict against=$GB note="
check "  └ c1 표식은 지움" [ "$(rdy)" = 1 ]
check "  └ wt queue에 [충돌로 빠짐]" has "$(wq 2>&1)" "  main/c2  m2  0분 전 [충돌로 빠짐, 기준 ${GB:0:9}"
check "충돌 표식은 다음 flush가 쌓지 않음" has "$(wtg "$GR" "$H1" flush 2>&1)" "준비된 레인이 없습니다"
rc=0; out=$(wtg "$C2" m2 finish 2>&1) || rc=$?
check "주인의 finish는 rebase 충돌로 멈춤(지금처럼)" has "$out" "rebase 충돌"
(cd "$C2" && git rebase --abort)
wtg "$C2" m2 ready --cancel >/dev/null 2>&1
check "ready --cancel이 표식 지움" [ "$(rdy)" = 0 ]
wtg "$C1" "$H1" finish >/dev/null 2>&1 || true

scene "⑭-3 묶음 검증이 실패하면 아무것도 머지하지 않고 표식에 실패를 남김"
V1=$(gstart vf1); echo v1 >"$V1/vf1.txt"; commit "$V1" "vf1"
V2=$(gs2 vf2); echo v2 >"$V2/vf2.txt"; commit "$V2" "vf2"
wtg "$V1" "$H1" ready >/dev/null 2>&1; wtg "$V2" m2 ready >/dev/null 2>&1
git -C "$GR" fetch -q origin; GB=$(git -C "$GR" rev-parse origin/main)
rc=0; out=$(export VERIFY_HOOK="exit 1"; wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "검증 실패면 flush 1" [ "$rc" = 1 ]
check "  └ 안내" has "$out" "묶음 검증 실패. 아무것도 머지하지 않았습니다"
check "  └ main 그대로" bash -c "git -C '$GR' fetch -q origin && [ \"\$(git -C '$GR' rev-parse origin/main)\" = '$GB' ]"
check "  └ 두 표식 state=failed" bash -c "printf '%s\n%s\n' \"\$1\" \"\$2\" | grep -c 'state=failed against=$GB' | grep -x 2 >/dev/null" _ "$(rsubj refs/wt-ready/main/vf1)" "$(rsubj refs/wt-ready/main/vf2)"
check "  └ wt queue에 [묶음 검증 실패]" has "$(wq 2>&1)" "[묶음 검증 실패, 기준 ${GB:0:9}"
check "  └ 번호표·통합 워크트리 정리" bash -c "[ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ] && ! git -C '$GR' worktree list | grep -F .train- >/dev/null"

scene "⑭-4 finish가 차례를 받으면 다른 준비됨 레인을 함께 묶어 검증 한 번"
runs=$(verify_runs)
wtg "$V1" "$H1" ready >/dev/null 2>&1; wtg "$V2" m2 ready >/dev/null 2>&1
check "다시 ready: 같은 트리라 검증 없이 state=ready로" bash -c "[ $(verify_runs) = $runs ] && printf '%s' \"\$1\" | grep -F 'state=ready note=' >/dev/null" _ "$(rsubj refs/wt-ready/main/vf2)"
A3=$(gstart a3); echo a3 >"$A3/a3.txt"; commit "$A3" "a3"
git -C "$GR" fetch -q origin; GB=$(git -C "$GR" rev-parse origin/main)
rc=0; out=$(wtg "$A3" "$H1" finish 2>&1) || rc=$?
check "finish 0" [ "$rc" = 0 ]
check "  └ 검증 2회(이 레인 + 묶음)" [ "$(verify_runs)" = $((runs + 2)) ]
check "  └ 묶음 안내(내 레인 먼저)" has "$out" "묶음 머지 → a3 vf1 vf2"
check "  └ 세 레인 main에, 레인마다 커밋 하나" bash -c "git -C '$GR' fetch -q origin && for f in a3 vf1 vf2; do git -C '$GR' cat-file -e origin/main:\$f.txt || exit 1; done && [ \"\$(git -C '$GR' rev-list --count '$GB..origin/main')\" = 3 ]"
check "  └ 표식·번호표 비움" bash -c "[ $(rdy) = 0 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
check "  └ 내 레인 정리, 다른 레인 워크트리는 그대로" bash -c "[ ! -e '$A3' ] && [ -d '$V1' ] && [ -d '$V2' ]"
wtg "$V1" "$H1" finish >/dev/null 2>&1 || true; wtg "$V2" m2 finish >/dev/null 2>&1 || true
check "  └ 다른 레인은 그 주인 finish가 정리" bash -c "[ ! -e '$V1' ] && [ ! -e '$V2' ]"

scene "⑭-5 줄 서서 기다리던 finish는 앞 차례가 함께 머지한 것을 알아차리고 정리만 하고 0"
REL=$(WT_HOST=builder wq enter release --pid $$ 2>/dev/null)
W1=$(gstart w1x); echo w1 >"$W1/w1x.txt"; commit "$W1" "w1x"
W2=$(gs2 w2x); echo w2 >"$W2/w2x.txt"; commit "$W2" "w2x"
wtg "$W1" "$H1" finish >"$T/w1.out" 2>&1 & PW1=$!
untilf "$T/w1.out" "머지 순번"
wtg "$W2" m2 finish >"$T/w2.out" 2>&1 & PW2=$!
untilf "$T/w2.out" "머지 순번"
check "기다리는 두 finish가 준비됨으로 올림" [ "$(rdy)" = 2 ]
runs=$(verify_runs)
wql "$REL"
rc1=0; wait "$PW1" || rc1=$?; rc2=0; wait "$PW2" || rc2=$?
check "두 finish 모두 0" bash -c "[ $rc1 = 0 ] && [ $rc2 = 0 ]"
check "  └ 검증은 묶음 한 번" [ "$(verify_runs)" = $((runs + 1)) ]
check "  └ 기다리던 쪽 안내" has "$(cat "$T/w2.out")" "다른 곳의 묶음 머지에 함께 들어갔습니다"
check "  └ 둘 다 main에, 워크트리 정리" bash -c "git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:w1x.txt && git -C '$GR' cat-file -e origin/main:w2x.txt && [ ! -e '$W1' ] && [ ! -e '$W2' ]"
check "  └ 표식·번호표 비움" bash -c "[ $(rdy) = 0 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"

scene "⑭-6 두 기계가 동시에 flush해도 한 번만 머지"
X1=$(gstart x1); echo x1 >"$X1/x1.txt"; commit "$X1" "x1"
X2=$(gs2 x2); echo x2 >"$X2/x2.txt"; commit "$X2" "x2"
wtg "$X1" "$H1" ready >/dev/null 2>&1; wtg "$X2" m2 ready >/dev/null 2>&1
git -C "$GR" fetch -q origin; GB=$(git -C "$GR" rev-parse origin/main); runs=$(verify_runs)
wtg "$GR" "$H1" flush >"$T/fa.out" 2>&1 & PFA=$!
wtg "$GR2" m2 flush >"$T/fb.out" 2>&1 & PFB=$!
rca=0; wait "$PFA" || rca=$?; rcb=0; wait "$PFB" || rcb=$?
check "둘 다 0" bash -c "[ $rca = 0 ] && [ $rcb = 0 ]"
check "  └ 검증 한 번, 레인마다 커밋 하나(2)" bash -c "[ $(verify_runs) = $((runs + 1)) ] && git -C '$GR' fetch -q origin && [ \"\$(git -C '$GR' rev-list --count '$GB..origin/main')\" = 2 ]"
check "  └ 나중 쪽은 '준비된 레인이 없습니다'" bash -c "cat '$T/fa.out' '$T/fb.out' | grep -F '준비된 레인이 없습니다' >/dev/null"
check "  └ 표식·번호표 비움" bash -c "[ $(rdy) = 0 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
wtg "$X1" "$H1" finish >/dev/null 2>&1 || true; wtg "$X2" m2 finish >/dev/null 2>&1 || true

scene "⑭-7 wt.autobatch false·--priority critical이면 묶지 않음"
Y1=$(gs2 y1); echo y1 >"$Y1/y1.txt"; commit "$Y1" "y1"; wtg "$Y1" m2 ready >/dev/null 2>&1
git -C "$GR" config wt.autobatch false
Y2=$(gstart y2); echo y2 >"$Y2/y2.txt"; commit "$Y2" "y2"
rc=0; out=$(wtg "$Y2" "$H1" finish 2>&1) || rc=$?
git -C "$GR" config --unset wt.autobatch
check "autobatch false: 이 레인만 머지" bash -c "[ $rc = 0 ] && git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:y2.txt"
check "  └ 준비됨 레인은 그대로" bash -c "[ $(rdy) = 1 ]"
check "  └ y1은 main에 없음" mainlacks y1.txt
Y3=$(gstart y3); echo y3 >"$Y3/y3.txt"; commit "$Y3" "y3"
rc=0; out=$(wtg "$Y3" "$H1" finish --priority critical 2>&1) || rc=$?
check "critical: 이 레인만 머지" bash -c "[ $rc = 0 ] && git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:y3.txt"
check "  └ y1은 여전히 준비됨" bash -c "[ $(rdy) = 1 ]"
check "  └ y1은 main에 없음" mainlacks y1.txt
check "남은 준비됨은 flush로" bash -c "cd '$GR' && WT_HOST='$H1' PATH='$T/bin:$PATH' '$WT' flush >/dev/null 2>&1 && git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:y1.txt"
wtg "$Y1" m2 finish >/dev/null 2>&1 || true

scene "⑭-8 rebase 머지가 막힌 저장소: 자동 묶음 finish는 이 레인만 squash 머지, flush는 아무것도 머지 안 함"
Q1=$(gs2 q1); echo q1 >"$Q1/q1.txt"; commit "$Q1" "q1"; wtg "$Q1" m2 ready >/dev/null 2>&1
Q2=$(gstart q2); echo q2 >"$Q2/q2.txt"; commit "$Q2" "q2"
rc=0; out=$(export GH_FAIL_REBASE=1; wtg "$Q2" "$H1" finish 2>&1) || rc=$?
check "finish 0 + 이 레인만 머지" bash -c "[ $rc = 0 ] && git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:q2.txt"
check "  └ 안내" has "$out" "묶음 머지가 막혀 이 레인만 squash 머지합니다"
check "  └ q1은 main에 없고 여전히 준비됨" bash -c "! git -C '$GR' cat-file -e origin/main:q1.txt 2>/dev/null && [ $(rdy) = 1 ]"
rc=0; out=$(export GH_FAIL_REBASE=1; wtg "$GR" "$H1" flush 2>&1) || rc=$?
check "flush는 1 + 표식 그대로" bash -c "[ $rc = 1 ] && [ $(rdy) = 1 ]"
check "  └ 번호표·묶음 브랜치 정리" bash -c "[ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ] && [ -z \"\$(git --git-dir='$G' for-each-ref refs/heads/wt/batch-)\" ]"
wtg "$GR" "$H1" flush >/dev/null 2>&1 || true; wtg "$Q1" m2 finish >/dev/null 2>&1 || true
check "  └ 막힘이 풀린 뒤 flush로 머지·정리" bash -c "git -C '$GR' fetch -q origin && git -C '$GR' cat-file -e origin/main:q1.txt && [ ! -e '$Q1' ] && [ $(rdy) = 0 ]"

ROOT="$(cd "$(dirname "$WT")/.." && pwd)"
check "변수 바로 뒤에 한글이 붙은 곳 없음" python3 -I -c 'import re,sys
bad=[f"{p}:{i}" for p in sys.argv[1:] for i,l in enumerate(open(p,encoding="utf-8"),1) if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[\uac00-\ud7a3]",l)]
print(*bad,sep="\n"); sys.exit(1 if bad else 0)' "$WT" "$ROOT"/hooks/* "$ROOT"/install.sh "$ROOT"/uninstall.sh

bash -n "$WT"
echo "결과: 통과 $pass, 실패 $fail"
[ "$fail" = 0 ]
