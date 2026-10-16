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
check() { local d=$1; shift; if "$@"; then echo "  ok   $d"; pass=$((pass + 1)); else echo "  FAIL $d"; fail=$((fail + 1)); fi; }
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

echo "① 다른 기준 레인의 앞선 수·반영 판정"
V1=$(start v2-a --base v2)
echo lane >"$V1/c.txt"; commit "$V1" "v2 lane"
V0=$(start v2-empty --base v2)        # 커밋 없는 v2 레인: v2 기준으론 반영됨, main 기준으론 +1로 오판됐다
out=$("$WT" list 2>&1)
check "v2 레인 +1(main 기준이면 +2)" has "$out" "$V1  wt/v2-a  +1 [기준 v2]"
check "빈 v2 레인 [v2에 반영됨]" has "$out" "$V0  wt/v2-empty  +0 [기준 v2] [v2에 반영됨]"
check "main 반영 표시가 v2 레인에 안 붙음" hasnt "$out" "[main에 반영됨]"

echo "② 기준으로 쓰이는 브랜치를 gc가 지우지 않음"
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

echo "③ wt verify 뒤 같은 트리면 finish가 검증을 건너뜀"
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

echo "④ 줄 단위 충돌 예고"
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

echo "⑤ 기존 동작 회귀"
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
echo "⑥ 합치기 커밋이 있는 통합 레인"
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

echo "⑦ 머지 잠금(flock): 쥔 쪽이 살아 있으면 기다리고, 죽으면 바로 풀림"
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

echo "⑧ wt train: 쌓기·충돌 레인 빼기·검증 한 번·레인별 커밋"
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

echo "⑨ wt train: 거절·실패하면 아무것도 머지 안 함"
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

echo "⑩ wt train: 검증 중 레인에 생긴 변경은 지우지 않음"
W1=$(start w1); echo w1 >"$W1/w1.txt"; commit "$W1" "w1"
W2=$(start w2); echo w2 >"$W2/w2.txt"; commit "$W2" "w2"
rc=0; out=$(VERIFY_HOOK="(cd '$W1' && echo late >late.txt && git add -A && git commit -qm late); echo dirty >>'$W2/w2.txt'" "$WT" train w1 w2 2>&1) || rc=$?
check "남긴 레인이 있으면 종료 코드 3" [ "$rc" = 3 ]
check "쌓은 내용은 main에" bash -c "git -C '$R' cat-file -e origin/main:w1.txt && git -C '$R' cat-file -e origin/main:w2.txt"
check "늦은 커밋은 아직 main에 없음" bash -c "! git -C '$R' cat-file -e origin/main:late.txt 2>/dev/null"
check "두 레인 모두 남음(커밋·미커밋 보존)" bash -c "[ -f '$W1/late.txt' ] && grep -q dirty '$W2/w2.txt'"
check "남긴 레인 안내" has "$out" "쌓은 뒤 새 커밋·미커밋 변경이 생겨 남긴 레인"

echo "⑪ gc: 강제 종료로 남은 train 통합 워크트리"
DEAD=$(bash -c 'echo $$')
git -C "$R" worktree add -q --detach "$R.wt/.train-$DEAD" origin/main
check "끝난 pid의 .train- 워크트리 정리" has "$("$WT" gc --apply 2>&1)" "정리 대상(끝난 train의 통합 워크트리) $R.wt/.train-$DEAD"
check "실제로 지워짐" [ ! -e "$R.wt/.train-$DEAD" ]

echo "⑫-0 기계 간 선점: wt claim / unclaim / claims"
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

echo "⑫ wt train: GitHub 경로(gh 흉내, 원격 주소에 github.com)"
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
              read -r b h <"$GH_STATE/pr"; c=$(mktemp -d); git clone -q "$GH_ORIGIN" "$c"
              # GitHub처럼: 헤드가 --match-head-commit과 다르면 거절. 기준이 움직였어도 같은 줄 충돌만 없으면 머지한다.
              [ -z "$want" ] || [ "$(git -C "$c" rev-parse "origin/$h")" = "$want" ] || { rm -rf "$c"; exit 1; }
              case $m in
                --rebase) (cd "$c" && git checkout -q "$h" && git rebase -q "origin/$b" && git push -q origin "HEAD:$b") ;;
                --squash) (cd "$c" && git checkout -q "$b" && git merge -q --squash "origin/$h" && git commit -qm "$subj" && git push -q origin "HEAD:$b") ;;
                *) exit 1 ;;
              esac; rm -rf "$c"; touch "$GH_STATE/merged" ;;
  "pr close") read -r b h <"$GH_STATE/pr"; git --git-dir="$GH_ORIGIN" branch -D "$h" >/dev/null ;;
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

echo "⑫-1 차례를 받은 뒤 재확인: 검증 중에 다른 기계가 main에 머지하면 차례를 쥔 채 다시 올려 검증"
export WT_QUEUE_POLL=1 WT_QUEUE_BEAT=2   # 갱신 2초 → 같은 host의 끝난 pid는 갱신이 6초 넘게 멈춰야 낡음
qempty() { [ -z "$(git ls-remote "$G" 'refs/wt-queue/*')" ]; }
# 대기열 번호표 수(_head 제외)가 n이 될 때까지 기다린다(최대 15초).
qwait_n() { local c; for _ in $(seq 1 30); do c=$(git ls-remote "$G" 'refs/wt-queue/main/*' | grep -vc '/_head$' || true); [ "$c" = "$1" ] && return 0; sleep 0.5; done; return 1; }
wq() { (cd "$GR" && PATH="$T/bin:$PATH" exec "$WT" queue "$@"); }
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

echo "⑫-2 공개 흉내: 다른 기계의 release 번호표가 차례를 쥔 동안 finish·train은 기다렸다 머지"
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
wq leave "$REL"
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

echo "⑫-3 순번: 등급 → 번호, 차례를 쥔 번호표는 밀려나지 않음"
order() { wq 2>/dev/null | sed -n 's/^  [0-9]*\. [a-z]*  \([^ ]*\) .*/\1/p' | paste -sd ' ' -; }
QA=$(WT_HOST=ha wq enter merge --pid $$ 2>/dev/null)
bgq() { local h=$1; shift; (cd "$GR" && WT_HOST=$h PATH="$T/bin:$PATH" exec "$WT" queue enter "$@" --pid $$ --wait 60 >"$T/q-$h.out" 2>/dev/null) & }
bgq hb merge; PB=$!; qwait_n 2
bgq hc merge --priority critical; qwait_n 3
bgq hd release; PD=$!; qwait_n 4
bgq he merge; PE=$!; qwait_n 5
check "차례 쥔 normal 맨 앞, 그다음 critical → release → normal(먼저 온 순)" [ "$(order)" = "ha hc hd hb he" ]
check "  └ 기다리는 쪽은 아직 출력 없음" bash -c "[ ! -s '$T/q-hc.out' ] && [ ! -s '$T/q-hb.out' ]"
wq leave "$QA"
check "놓으면 critical이 차례를 받음" untilf "$T/q-hc.out" "refs/wt-queue/main/"
check "  └ 나머지는 그대로 기다림" bash -c "[ ! -s '$T/q-hd.out' ] && [ ! -s '$T/q-hb.out' ]"
bgq hf merge --priority critical; qwait_n 5
check "차례 쥔 critical 뒤에 새 critical, 그다음 release·normal" [ "$(order)" = "hc hf hd hb he" ]
wq leave "$(cat "$T/q-hc.out")"
check "다음 차례는 새 critical" untilf "$T/q-hf.out" "refs/wt-queue/main/"
kill "$PB" "$PD" "$PE" 2>/dev/null; wait "$PB" "$PD" "$PE" 2>/dev/null || true
wq leave "$(cat "$T/q-hf.out")"
check "기다리다 끝난 enter는 번호표를 지움" qempty

echo "⑫-4 낡은 번호표·시간 초과"
# 다른 기계 번호표를 직접 만든다: host pid kind 몇 초 전 → 번호 출력
qat() { local at=$(($(date +%s) - $4)) s id; id="${at}000-$1-$2"
  s=$(cd "$GR" && GIT_COMMITTER_DATE="@$at +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue host=$1 pid=$2 at=old kind=$3 priority=normal lane=- note=")
  git -C "$GR" push -q origin "$s:refs/wt-queue/main/$id"; echo "$id"; }
qhead() { local s; s=$(cd "$GR" && GIT_COMMITTER_DATE="@$(($(date +%s) - 2400)) +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue-head ticket=$1 at=old")
  git -C "$GR" push -q origin "$s:refs/wt-queue/main/_head"; }
O1=$(qat elsewhere 1 merge 2400); qhead "$O1"
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "40분 된 다른 기계 merge 차례는 넘겨받음" [ "$rc" = 0 ]
check "  └ 경고" has "$out" "경고: 낡은 번호표를 지웁니다(main/$O1)"
check "  └ 낡은 번호표 지워짐" [ -z "$(git ls-remote "$G" "refs/wt-queue/main/$O1")" ]
wq leave "$(printf '%s\n' "$out" | tail -n 1)"
O2=$(qat elsewhere 1 release 1200)
s=$(date +%s); rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 2 2>&1) || rc=$?
check "20분 된 다른 기계 release는 낡지 않음 → 시간 초과 3" [ "$rc" = 3 ]
check "  └ 2초 이상 기다림" [ $(($(date +%s) - s)) -ge 2 ]
check "  └ 시간 초과 안내" has "$out" "2초 기다렸지만 차례가 오지 않았습니다"
check "  └ 내 번호표는 지우고 남의 것은 둠" bash -c "[ \"\$(git ls-remote '$G' 'refs/wt-queue/main/*' | cut -f2)\" = 'refs/wt-queue/main/$O2' ]"
git -C "$GR" push -q origin ":refs/wt-queue/main/$O2"
O2=$(qat elsewhere 1 release 2400)
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "release도 30분이 넘으면 넘겨받음(90분 폐지)" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O2)' >/dev/null" _ "$out"
wq leave "$(printf '%s\n' "$out" | tail -n 1)"
O3=$(qat hx "$DEAD" merge 0)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "같은 host의 끝난 pid라도 갱신이 신선하면 지우지 않음(3)" [ "$rc" = 3 ]
check "  └ 그 번호표 남음" [ -n "$(git ls-remote "$G" "refs/wt-queue/main/$O3")" ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O3"
O3=$(qat hx "$DEAD" merge 10)
rc=0; out=$(WT_HOST=hx wq enter merge --pid $$ --wait 10 2>&1) || rc=$?
check "같은 host의 끝난 pid + 갱신이 주기 3배(6초) 넘게 멈춤 → 넘겨받음" bash -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -F '낡은 번호표를 지웁니다(main/$O3)' >/dev/null" _ "$out"
wq leave "$(printf '%s\n' "$out" | tail -n 1)"
O4=$(qat elsewhere "$DEAD" merge 0)
rc=0; WT_HOST=hx wq enter merge --pid $$ --wait 1 >/dev/null 2>&1 || rc=$?
check "다른 host의 pid는 끝났는지 몰라 넘겨받지 않음(3)" [ "$rc" = 3 ]
git -C "$GR" push -q origin ":refs/wt-queue/main/$O4"
check "대기열 비움" qempty
check "origin 없으면 queue 1" bash -c "cd '$T/noorigin' && ! '$WT' queue 2>/dev/null"
check "잘못된 kind 거절" bash -c "! (cd '$GR' && '$WT' queue enter deploy 2>/dev/null)"
check "빈 목록" has "$(wq 2>&1)" "비어 있음"

echo "⑫-5 --pid 필수·갱신 재시도·pid가 끝나면 지움·차례 잃음·옛 판 머지 선점"
qgone() { for _ in $(seq 1 30); do qempty && return 0; sleep 0.5; done; return 1; }
rc=0; (cd "$GR" && exec "$WT" queue enter release >/dev/null 2>&1) || rc=$?
check "--pid 없는 enter는 사용법 오류 2" [ "$rc" = 2 ]
check "  └ 번호표를 만들지 않음" qempty
QR=$(WT_HOST=hb wq enter merge --pid $$ 2>/dev/null)
chmod a-w "$G/refs/wt-queue/main"; sleep 3   # origin 쓰기 실패 동안 갱신 push가 실패한다
ct0=$(git --git-dir="$G" log -1 --format=%ct "$QR")
chmod u+w "$G/refs/wt-queue/main"; sleep 5
check "갱신 push가 실패해도 다음 주기에 다시 시도(갱신 시각이 나아감)" [ "$(git --git-dir="$G" log -1 --format=%ct "$QR")" -gt "$ct0" ]
wq leave "$QR"
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

echo "⑫-6 오래 사는 --pid: init·끝난 pid 거절, 갱신 상한, 오래 쥔 차례 표시"
rc=0; (cd "$GR" && exec "$WT" queue enter release --pid 1 >/dev/null 2>&1) || rc=$?
check "--pid 1 거절(2)" bash -c "[ $rc = 2 ] && [ -z \"\$(git ls-remote '$G' 'refs/wt-queue/*')\" ]"
rc=0; (cd "$GR" && exec "$WT" queue enter release --pid "$DEAD" >/dev/null 2>&1) || rc=$?
check "끝난 --pid 거절(2)" [ "$rc" = 2 ]
QR=$(WT_HOST=hb wq enter release --pid $$ --wait 0 --max-hold 1 2>/dev/null)
sleep 5; ct0=$(git --git-dir="$G" log -1 --format=%ct "$QR"); sleep 5
check "--max-hold가 지나면 pid가 살아 있어도 갱신을 멈춤" [ "$(git --git-dir="$G" log -1 --format=%ct "$QR")" = "$ct0" ]
check "  └ 목록에 [갱신 멈춤]" has "$(wq 2>&1)" "[갱신 멈춤"
wq leave "$QR"
O5=$(qat elsewhere 1 merge 0)
s=$(cd "$GR" && GIT_COMMITTER_DATE="@$(($(date +%s) - 4000)) +0000" git commit-tree "$(git hash-object -t tree -w /dev/null)" -m "wt-queue-head ticket=$O5 at=old")
git -C "$GR" push -q origin "$s:refs/wt-queue/main/_head"
check "1시간 넘게 쥔 차례 표시" has "$(wq 2>&1)" "[차례 66분째 쥠 — 오래 쥔 차례]"
git -C "$GR" push -q origin ":refs/wt-queue/main/_head" ":refs/wt-queue/main/$O5"
check "  └ 대기열 비움" qgone

echo "⑫-7 기계 간 같은 이름 레인: start 거부·finish가 남의 브랜치를 덮어쓰지 않음"
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
check "origin을 못 보면(오프라인) 경고만 하고 start 진행" bash -c "[ $rc = 0 ] && [ -d '$OC.wt/off' ]" && check "  └ 경고" has "$out" "확인하지 못했습니다"
git --git-dir="$G" update-ref -d refs/heads/wt/dup; git --git-dir="$G" update-ref -d refs/heads/wt/b7
git -C "$GR" worktree remove --force "$B7"; git -C "$GR" branch -q -D wt/b7

echo "⑦ gc의 24시간 판정은 status가 건드리는 파일을 사용 흔적으로 안 본다"
OLD=$(start gc-old); FRESH=$(start gc-fresh)
OGD=$(git -C "$OLD" rev-parse --absolute-git-dir)
find "$OGD" "$OLD" -exec touch -h -t 202001010000 {} + 2>/dev/null
git -C "$OLD" status >/dev/null; git -C "$OLD" status --porcelain >/dev/null   # gd mtime·index를 지금으로 갱신
out=$("$WT" gc 2>&1)
check "오래된 레인은 status 뒤에도 정리 대상" has "$out" "정리 대상 워크트리 $OLD"
check "방금 만든 레인은 24시간 내 사용으로 유지" has "$out" "유지(24시간 내 사용) $FRESH"
git -C "$R" worktree remove --force "$FRESH" 2>/dev/null || true; git -C "$R" branch -D wt/gc-fresh >/dev/null 2>&1 || true

ROOT="$(cd "$(dirname "$WT")/.." && pwd)"
check "변수 바로 뒤에 한글이 붙은 곳 없음" python3 -I -c 'import re,sys
bad=[f"{p}:{i}" for p in sys.argv[1:] for i,l in enumerate(open(p,encoding="utf-8"),1) if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[\uac00-\ud7a3]",l)]
print(*bad,sep="\n"); sys.exit(1 if bad else 0)' "$WT" "$ROOT"/hooks/* "$ROOT"/install.sh "$ROOT"/uninstall.sh

bash -n "$WT"
echo "결과: 통과 $pass, 실패 $fail"
[ "$fail" = 0 ]
