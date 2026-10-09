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
check "충돌로 뺀 레인이 있으면 종료 코드 2" [ "$rc" = 2 ]
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
check "기준 브랜치(v2) 워크트리는 거절" has "$("$WT" train v2 2>&1 || true)" "기준 브랜치는 레인으로 묶지 않습니다: v2"
check "v2 원격 그대로" git -C "$R" show-ref --verify --quiet refs/remotes/origin/v2
git -C "$R" worktree remove "$T/v2-checkout"
git -C "$R" worktree lock --reason manual "$U1"
check "git worktree lock(에이전트 외 사유) 레인은 거절" has "$("$WT" train u1 2>&1 || true)" "잠긴 워크트리입니다"
git -C "$R" worktree unlock "$U1"

echo "⑩ wt train: 검증 중 레인에 생긴 변경은 지우지 않음"
W1=$(start w1); echo w1 >"$W1/w1.txt"; commit "$W1" "w1"
W2=$(start w2); echo w2 >"$W2/w2.txt"; commit "$W2" "w2"
rc=0; out=$(VERIFY_HOOK="(cd '$W1' && echo late >late.txt && git add -A && git commit -qm late); echo dirty >>'$W2/w2.txt'" "$WT" train w1 w2 2>&1) || rc=$?
check "남긴 레인이 있으면 종료 코드 2" [ "$rc" = 2 ]
check "쌓은 내용은 main에" bash -c "git -C '$R' cat-file -e origin/main:w1.txt && git -C '$R' cat-file -e origin/main:w2.txt"
check "늦은 커밋은 아직 main에 없음" bash -c "! git -C '$R' cat-file -e origin/main:late.txt 2>/dev/null"
check "두 레인 모두 남음(커밋·미커밋 보존)" bash -c "[ -f '$W1/late.txt' ] && grep -q dirty '$W2/w2.txt'"
check "남긴 레인 안내" has "$out" "쌓은 뒤 새 커밋·미커밋 변경이 생겨 남긴 레인"

echo "⑪ gc: 강제 종료로 남은 train 통합 워크트리"
DEAD=$(bash -c 'echo $$')
git -C "$R" worktree add -q --detach "$R.wt/.train-$DEAD" origin/main
check "끝난 pid의 .train- 워크트리 정리" has "$("$WT" gc --apply 2>&1)" "정리 대상(끝난 train의 통합 워크트리) $R.wt/.train-$DEAD"
check "실제로 지워짐" [ ! -e "$R.wt/.train-$DEAD" ]

echo "⑫ wt train: GitHub 경로(gh 흉내, 원격 주소에 github.com)"
G="$T/github.com/gh.git"; GS="$T/ghstate"; mkdir -p "$T/github.com" "$GS"
git clone -q --bare "$T/origin.git" "$G"
cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
echo "gh $*" >>"$GH_STATE/calls"
case "$1 $2" in
  "pr create") shift 2; while [ $# -gt 0 ]; do case $1 in --base) b=$2; shift 2 ;; --head) h=$2; shift 2 ;; *) shift ;; esac; done
               echo "$b $h" >"$GH_STATE/pr"; rm -f "$GH_STATE/merged" ;;
  "pr list") [ -f "$GH_STATE/pr" ] && [ ! -f "$GH_STATE/merged" ] && echo 7 || true ;;
  "pr merge") [ "$4" = --rebase ] || exit 1; [ -z "${GH_FAIL_MERGE-}" ] || exit 1
              read -r b h <"$GH_STATE/pr"; c=$(mktemp -d); git clone -q "$GH_ORIGIN" "$c"
              (cd "$c" && git checkout -q "$h" && git rebase -q "origin/$b" && git push -q origin "HEAD:$b"); rm -rf "$c"; touch "$GH_STATE/merged" ;;
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

ROOT="$(cd "$(dirname "$WT")/.." && pwd)"
check "변수 바로 뒤에 한글이 붙은 곳 없음" python3 -I -c 'import re,sys
bad=[f"{p}:{i}" for p in sys.argv[1:] for i,l in enumerate(open(p,encoding="utf-8"),1) if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[\uac00-\ud7a3]",l)]
print(*bad,sep="\n"); sys.exit(1 if bad else 0)' "$WT" "$ROOT"/hooks/* "$ROOT"/install.sh "$ROOT"/uninstall.sh

bash -n "$WT"
echo "결과: 통과 $pass, 실패 $fail"
[ "$fail" = 0 ]
