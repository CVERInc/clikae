# DESIGN-tmux: Clikae Tmux Orchestration

**Status**: Active
**Scope**: This document owns the lifecycle, environment isolation, and terminal rendering (Tmux) rules for Clikae tanks.
**Boundary**: This is the Single Source of Truth for Tmux interactions. Where `orchestration.md` or `DESIGN-runtime.md` disagrees with this file regarding Tmux, this file wins.

## 0. Session 名稱前綴（2026-08-22 起 `clikae-`）

`clikae-<engine>-<tank>[-<argv 摘要>]`。舊前綴是 `ck-`，從 v0.4 用到 0.28.2 ——
那個縮寫**從來沒有被決定過**：README、formula、alias、文件裡都沒有它，它只活在
使用者唯一會讀到它的地方（`tmux ls`）。

🔴 **舊前綴不再被讀，因為它不再存在。** 改名是**搬遷**不是字串替換，而搬遷分兩層：

- **一次性全機掃描**（`_state_migrate_1`，state schema v1 → v2）：第一次跑新版時，把機器上
  **每一個** `ck-*` 都改名。這一步不能省成「遇到才改」——`tmux_sessv` 只在有人啟動那個 tank
  時才被呼叫，所以一個你今天不會進去的 tank 會被留下，而看板只讀一個前綴時它就是
  **活著但看不見**，`clikae <tank>` 還會在旁邊再開一個。逐 id 的改名搆不到它，逐機器的掃描可以。
- **遇到就改名**（`tmux_sessv`，約 6 行）：接住漏網。同一台機器上可能還裝著舊版 clikae
  （維護者的機器上就有 brew 的 0.27.0），它會在遷移跑完之後繼續造出舊名字——一次性的掃法
  留不住這些。

⚠️ **殘留的一種情況**：舊 binary 造出來的 session，在還沒有人啟動進去之前撞到用量上限，
不會拿到守望者（`wake_sessions_for` 只比對一個前綴）。啟動一次就會被收回來。

被改名的 session 裡的守望者會自己乾淨退出（它的指令裡烤著舊名字），`switch` 在兩條路上
都會重新掛一個，而 `wake_attach_watcher` 是冪等的。

前綴只有一個定義（`lib/core/tmux.sh` 的 `CLIKAE_SESS_PREFIX`）。它先前以字面字串
散在 64 個地方，那正是本文件開頭那個「規則說要收斂、函式從沒被寫出來、四個呼叫端
各自漂移」的形狀在等著重演。

🔴 **空值不可以安靜。** 前綴未設時，GC 的 glob 會匹配不到任何東西（無聲的 no-op），
而 `live.sh` 的 `^(|)` 會匹配**每一行**——看板會把使用者手動開的 session 全部認領。
兩邊都要在空值時拒絕執行。

## 1. 核心哲學 (Core Philosophy)
- `clikae` 是業務邏輯與流程大腦（Source of Truth）。
- `tmux` 是純粹的狀態容器（Persistence Layer），負責維持 Shell 存活。
- 不綁架使用者：若 `clikae` 失效，使用者仍可直接用 `tmux attach` 取回狀態。

## 2. 邊界條件與防呆規範 (Edge Cases & Rules)

### Rule 1: 全域設定與視窗佔用 (Global Config & Exclusivity)
- **症狀**：開機後首個背景任務設定 `history-limit` 失敗導致無卷軸。（多 client 共存是刻意的設計選擇）
- **收據**：
  ```
  $ tmux show-options -g window-size
  window-size latest
  $ tmux new-session -d -x 200 -y 50 -s s ; # 只有 Mac client（200x50）接上
  200x49
  $ # PineNote client（60x20）也接上之後
  60x19
  $ # PineNote 離開之後
  200x49
  ```
- **規範**：
  必須將全域設定與建立 Session 串在同一個指令，確保 Server 生命週期不中斷：
  ```bash
  tmux set-option -g history-limit 50000 \; new-session -d -e "CLIKAE_TANK_NAME=$tank" -s "clikae-<run_id>" "..."
  ```
  🔴 **這條被違反過，而且是靜音的。** `burn.sh` 用的是裸的 `tmux new-session -d`，一個前綴都沒有。因為 `switch` 之後會補上全域選項，所以只有「burn 是第一個跑的東西」那一瞬間看得到；量到的（2026-08-15，隔離 socket）：
  ```
  $ # 沒有既存 server，用 burn 生一顆，趁它還活著問
  $ tmux show-options -gv history-limit
  2000          # tmux 的預設，不是我們的 50000
  ```
  收斂到 `tmux_spawn_session` 之後回到 50000。`tests/bats/tmux-spawn.bats` 釘住它——那個測試在修之前是紅的。
  ⚠️ **量的時候 server 必須還活著**：`exit-empty` 讓 server 隨最後一個 session 消失，而對死掉的 server 問選項會**默默起一顆新的**、回答 tmux 的預設值——長得跟 bug 一模一樣，不管 bug 在不在。
  互動模式時使用 `tmux attach -t "clikae-<tank>"`，不再強制使用 `-D` 踢除舊連線（允許在多個視窗中同時查看同一個 session，將控制權交由使用者自行協調）。`window-size latest` 下最近使用的 client 決定尺寸，兩個 client 並存不會坍塌，離開會自動彈回。這是「不需要 -D」的真正理由。

- **每 session（非全域）的 clikae 選項清冊**：`status-left` / `status-left-length` / `status-right` / `status-right-length` / `status-interval` / `status-justify` / `status-format`（全部在 `tmux_status_line`，2026-09 #77 之前只有前兩個、且在 `tmux_label`；見 Rule 10）之外，2026-09 起新增 `@clikae_session_id`（`tmux_set_session_id`，`lib/core/tmux.sh`）—— clikae 寫進 tmux 的第一個 per-session 使用者選項，記錄「這個視窗當初是為了哪個逐字稿 session id 開的」，`live_session_id`（`lib/core/live.sh`）讀回。與上面的全域選項不同，它是單一 session 作用域、`set-option -t "=$session:"`，不會漏到同一 server 的其他 session；但同樣只在 `tmux_spawn_session` 剛建立的那個 session 上寫，且只在真的 spawn（非 attach）時寫——Rule 7 的「出生時繼承」對它不適用（它不是 server 出生時決定的，是每次 spawn 各自決定的），但同一個道理仍然成立：寫的時機只有一個地方，讀的時候永遠先查 option、查不到才退回 `~/.clikae/state/<session>.session_id` 鏡像檔。

- **`base-index` 是全域選項，clikae 從來沒有設過它，讀的一方不能假設它是 0**：2026-09 起 `live_engine_alive`（`lib/core/live.sh`）需要問「這個 session 的引擎視窗還在不在」，一度用 `tmux list-windows -F '#{window_index}'` 比對字面 `0`——跟這條規則本身講的道理正是同一件事（`history-limit` 那個收據）：`tmux_spawn_session` 沒有設 `base-index` 不代表它是 0，代表它繼承使用者 `~/.tmux.conf` 裡設的任何值，而 `set -g base-index 1` 是很常見的一行。在 `base-index 1` 的機器上，引擎唯一的視窗落在 index 1，字面比對 0 因此把每一個健康 session 都判成「引擎已死」（2026-09-12 R4 review, R4-P2-1）。修法改問視窗**名稱**：是否存在一個不是 `wake` 守望者（`^wake( |$)`，`wake_attach_watcher` 開的那個）的視窗——與 `tmux_sess_has_engine`（`lib/core/tmux.sh`）同一個問法，同一層已經有正典答案。任何要問「這是不是某個特定視窗」的呼叫點，一律用名稱或這個 per-session 選項，不用數字位置。

- **2026-09 起新增六條全域 key binding ＋ 兩個全域選項（touch-scroll，P3-4 2026-09 R2 review）**：`bind-key -T root/copy-mode/copy-mode-vi MouseDown1Pane`／`MouseUp1Pane`（六條，`lib/core/tmux.sh` 的 touch-scroll 區塊）與 `@clikae_touch_scroll`／`@clikae_touch_scroll_lines`（`set-option -og`）。跟 `history-limit`／`mouse on` 同一條鏈、同一個作用域（整台 server，不是這個 session），但多一層閘門：`_tmux_touch_scroll_floor_met` 要求 **tmux ≥ 3.1**（`set-option -p`/`-pu`，CHANGES FROM 3.0 TO 3.1）——低於這個版本，`mouse on` 照裝，這六條 binding 與兩個選項整串跳過（不是裝一半，見 Rule 1 開頭 `history-limit` 那條「串在同一個指令」的規範）。`bind-key` 沒有 `-o`，會覆寫使用者自己在 root table 上已經設過的 `MouseDown1Pane`/`MouseUp1Pane`（`docs/usage.md` 已寫明）。細節、每個 binding 的理由、以及 choose-mode/clock-mode 的邊界見 `lib/core/tmux.sh` 本體的行內註解（Rule 9 收 `mouse on`/`set-clipboard` 那兩個更早的全域選項）。

### Rule 2: tmux 是便利層，不是相依（三個出口）

- **症狀**：沒有 tmux 的機器、`TERM` 畫不了的終端機、或 CI，`clikae <engine> <tank>` 應該照樣把引擎跑起來，而不是壞掉或把 session 丟在背景。
- **收據**：
```
$ # 1) 沒有 tmux（把它從 PATH 拿掉，不是用會失敗的替身——替身 command -v 找得到）
$ bats tests/bats/scrollback.bats
ok 1 … # skip tmux not installed (switch falls back to a direct run)

$ # 2) TERM 畫不動：new-session -d 會成功，失敗的是 attach
$ TERM=dumb tmux attach -t t
open terminal failed: not a terminal
$ CK_PTY_TERM=dumb bats -f "cannot attach" tests/bats/scrollback.bats
ok 2 switch still runs the engine when tmux cannot attach, and leaves nothing behind

$ # 3) 真的能用時，接手不重跑
$ bats tests/bats/roam.bats
ok 1 a second client attaches to the running tank instead of starting it again
ok 2 called from inside tmux, switch moves the client instead of nesting
```
- **規範**：
  三個出口全部收斂到同一組函式，別各寫一份（互動路徑與 dry-tank carry 路徑就是這樣漂開的，carry 那份少了守衛、少了 `-S -`、attach 失敗也沒人接）：
  ```bash
  tmux_usable   # command -v tmux && [ -t 0 ] && [ -t 1 ]
  tmux_attach   # attach；被拒就收掉「我們剛建的」session，回 1
  ```
  ⚠️ **這條規則寫下來之後，兩年內沒有被實作。** 這份文件從 v0.4 就說要收斂到同一組函式，也在 Rule 5 引用了一個叫 `clikae_spawn_session` 的封裝——而那個名字在文件裡出現三次、在原始碼裡出現**零次**。四個呼叫點各自手寫，然後照這條規則預測的方式漂開（見 Rule 1 的 burn 收據）。2026-08-15 補上 `lib/core/tmux.sh`，函式實名為 `tmux_spawn_session`。
  🔴 **推論：這份文件裡任何「應該收斂到 X」的句子，都要能指著一個真的存在的 X。**

  🔴 **而且要問對問題。** 2026-08-15 收斂完之後，`clikae resume` 仍然沒有 tmux —— 它從 2026-06-26 就直接 `adapter_run`，而加 tmux 層的 `62b33a2` 只動了 `switch.sh` 和 `burn.sh`。它躲過稽核不是因為藏得好，是因為稽核問的是「**誰呼叫 tmux**」：那份清單裡本來就不可能有它。找呼叫者只找得到「已經加入的人之間的漂移」，找不到「從來沒加入的那一個」。
  會找到它的問題是「**誰啟動引擎**」，而那有一份確定的清單 —— 每一個 `adapter_run` 呼叫點：
  ```
  run.sh      switch 在 tmux 不可用時的 fallback 原語   ← 刻意
  relay.sh    carry 的同一種 fallback 原語               ← 刻意
  switch.sh:481  --ephemeral                            ← 刻意
  switch.sh   主路徑                                     ← 有 tmux
  resume.sh   ← 唯一站錯邊的面向使用者入口
  ```
  **缺席對「搜尋存在」的方法是隱形的。** 這跟 `clikae_spawn_session` 文件有三次、程式碼零次是同一種盲點，只是換一層。
  **能不能用 tmux 由 tmux 決定，不要用 `tput` 之類的代理去猜**——PineNote 的 ssh session 進來就是 `TERM=dumb`，拿 TERM 當前置判斷會把漫遊從唯一需要它的裝置上關掉。
  attach 被拒時要 `kill-session`：`new-session -d` 已經把引擎啟動了，留著就是一個沒人看得見、卻在燒額度的 session。

  🔴 **`ssh host '指令'` 這種一次性形式拿不到 tmux**，而 §2 的 PineNote 進入法（`RemoteCommand clikae`）正是這一種。從真機量到：

  ```
  $ # PineNote --ssh--> Mac，指令直接交給 ssh
  STDIN=yes  STDOUT=no  TTY=/dev/ttys010  TERM=tmux-256color

  $ # PineNote --ssh--> 互動 shell，再打指令
  session ck-codex-roamtest 建立，90x27（貼合 PineNote 的 90x28），引擎啟動 1 次
  ```

  stdout 是管線，守衛正確地降級成直接跑——沒有壞掉，但**也沒有持久化**。要漫遊就得先拿到 shell 再下指令。

### Rule 2b: scrollback 重播只在 macOS 驗證過（誠實範圍，**原因未解**）

- **症狀**：離開 session 時把畫面倒回終端機。這個功能在 ubuntu tmux 3.4 上**從來沒有作用過**，而測試在 macOS 上每次都綠 —— 直到 2026-08-15 才有人去看 Linux 的 CI。
- **量到的**（2026-08-15，ubuntu tmux 3.4 / macOS tmux 3.7b）：
  ```
  引擎在 pane 內自己擷取（還活著時）   capture-bytes=1717   ← 擷取本身沒問題
  帶 -t <session名> 擷取              0 bytes              ← 已修：拿掉 -t
  scrollback 檔（10ms 全程追蹤）       從未出現
  state 目錄事後                      空的
  ```
  重導向就算指令失敗也會建檔，所以「檔案不存在」＝**那個指令從未執行**。
- 🔴 **已經排除的解釋**（別再試一次）：
  ```
  「pane 被硬拆」          ✗ 探針證明 pane 存活：sh -c 'true; touch X'      → SURVIVES
                             連 exec 形狀也存活：sh -c '<exec 腳本>; touch X' → SURVIVES
  「順序執行來不及」       ✗ 換成 bash EXIT trap，同樣沒跑
  「時序競速」             ✗ 引擎已改成等到 client attach 才退出，仍然沒跑
  「-t 目標解析差異」       ✗ 已拿掉 -t（那是另一個真 bug，已修），沒有改變結果
  ```
- **規範**：
  1. **原因未知。** 這條規則記錄的是一個開放問題，不是一個解釋。任何要補上的人，先讀上面那份「已排除」清單。
  2. 測試在非 Darwin 平台 `skip` 並指回這裡 —— **不是刪掉**。功能在 macOS 上是好的，缺口是真的、寫下來了，而一個帶理由的 skip 是邀請修復，不是掩蓋。
  3. 這是 Rule 2「tmux 是便利層」的延伸：**功能誠實降級，不假裝跨平台**。
  4. ⚠️ 本節前一版曾宣稱原因是「pane 被硬拆」。那是在探針量出 SURVIVES 之前寫的，**是錯的**，已更正。寫進 SSOT 的推論若沒有收據，下一個人會拿它當前提。

### Rule 3: 背景無頭任務 (Headless Burn & Coroner Pattern)
- **症狀**：輸出被 `tee` 吞噬、Exit Code 遺失，OOM 或 `SIGKILL` 無法留下死亡證明，併發執行覆蓋彼此的 Log。
- **收據**：
  - `(exit 42) 2>&1 | tee /tmp/test.log; echo ${PIPESTATUS[0]}` 回傳 42。若只用 `$?` 會拿到 `tee` 的 0。
  - OOM 或 SIGKILL (kill -9) 發生時，Bash Trap 不會被觸發，不會留下 `_exit` 檔案。
- **規範**：
  1. 使用獨立的 `CLIKAE_RUN_ID` 作為檔案與 Session 命名，解決併發覆蓋。
  2. `burn_wrapper.sh` 必須在開頭宣告變數與建立路徑：
  ```bash
  #!/usr/bin/env bash
  : "${CLIKAE_RUN_ID:?Missing CLIKAE_RUN_ID}"
  mkdir -p "$HOME/.clikae/logs" "$HOME/.clikae/state"
  chmod 0700 "$HOME/.clikae/logs" "$HOME/.clikae/state"
  set -o pipefail
  ```
  3. 必須採用嚴格的法醫陷阱 (Coroner Trap)，並利用 `PIPESTATUS[0]` 擷取真實退出碼：
  ```bash
  trap 'echo 129 > "$HOME/.clikae/state/${CLIKAE_RUN_ID}_exit"; exit 129' HUP
  trap 'echo 130 > "$HOME/.clikae/state/${CLIKAE_RUN_ID}_exit"; exit 130' INT
  trap 'echo 143 > "$HOME/.clikae/state/${CLIKAE_RUN_ID}_exit"; exit 143' TERM
  trap 'echo $? > "$HOME/.clikae/state/${CLIKAE_RUN_ID}_exit"; exit' EXIT
  
  ( eval "$CK_TARGET_CMD" ) 2>&1 | tee "$HOME/.clikae/logs/${CLIKAE_RUN_ID}.log"
  rc=${PIPESTATUS[0]}
  exit $rc
  ```
  4. 查驗死亡證明的邏輯（Status Check）若發現 Session 已不存在且 `_exit` 檔案遺失，一律視為 `255` (SIGKILL / OOM / 還沒開始寫)。
  
  FIRES: 觸發 HUP 陷阱
  ```
  $ bash -c 'trap "echo 129 > /tmp/test_exit; exit 129" HUP; kill -HUP $$'
  rc=129
  ```

### Rule 4: SSH 憑證過期與全域漫遊 (The Stale Socket Symlink)
- **症狀**：長時間運行的 Session 在 SSH 斷線重連後，失去 Git 權限。
- **收據**：
  - `tmux set-environment` 無法更新既有 shell 內的變數，只對之後新開的 pane 有效。
  - 防禦性機制，維護者環境目前未觸發。兩端都沒有轉發 agent，git 走 HTTPS + Keychain，根本不碰 `SSH_AUTH_SOCK`：
    ```
    $ ssh-add -l
    The agent has no identities.
    
    $ 41 個 repo 的 remote 協定
      38 https（credential.helper=osxkeychain）
       3 git@
    
    $ ssh pinenote 'grep -i forwardagent ~/.ssh/config'
    （無輸出）
    ```
- **規範**：
  這是一個便宜且無害的防禦性機制。只有在有人打開 `ForwardAgent`，或改用 SSH remote 而且靠 agent 認證時，這個機制才會真的發揮作用。
  使用單一全域軟連結（Trade-off: 切換裝置時，所有運行中的 Tanks 會一起轉換認證；若未連線，所有 Tanks 的 Git 都會 hang 或報錯。這是 Zero-Config 的妥協，優點是舊 Session 不需重啟 Agent 即可恢復權限）。
  ```bash
  if [[ -n "$SSH_AUTH_SOCK" && -S "$SSH_AUTH_SOCK" ]]; then
    mkdir -p "$HOME/.clikae/state"
    chmod 0700 "$HOME/.clikae/state"
    ln -sf "$SSH_AUTH_SOCK" "$HOME/.clikae/state/clikae_ssh_auth.sock"
  fi
  ```
  並在建立 Session 的函式中固定注入 `-e "SSH_AUTH_SOCK=$HOME/.clikae/state/clikae_ssh_auth.sock"`。
  
  FIRES: 模擬無效的 SSH_AUTH_SOCK
  ```
  $ SSH_AUTH_SOCK=/tmp/fake bash -c 'if [[ -n "$SSH_AUTH_SOCK" && -S "$SSH_AUTH_SOCK" ]]; then echo "VALID"; else echo "INVALID"; fi'
  INVALID
  rc=0
  ```

### Rule 5: 名稱過濾與巢狀防護 (Naming & Nesting Guard)
- **症狀**：Tank 名稱含空格導致 Word-Splitting，或巢狀執行 `clikae to` 導致自動化被 rc=1 打斷。
- **收據**：實測巢狀 attach `tmux new-session -A -s ...` 時，會噴出 `sessions should be nested with care, unset $TMUX to force` 並且直接 `rc=1`。
- **規範**：
  1. 不依賴 Shell Quoting，直接在入口實施白名單：
  ```bash
  case "$tank" in *[!a-zA-Z0-9_-]*) exit 2 ;; esac
  ```
  2. 若在已經身處 tmux 內部的環境下再次呼叫切換指令：
  ```bash
  if [ -n "$TMUX" ]; then
    # 若為互動模式，切換畫面；若為無頭腳本，則靜默略過 switch-client 避免打斷自動化
    CURRENT_PANE_SESSION=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
    tmux has-session -t "clikae-<tank>" 2>/dev/null || tmux_spawn_session --session "clikae-<tank>" …
    CLIENTS=$(tmux list-clients -t "$CURRENT_PANE_SESSION" 2>/dev/null)
    if [ -n "$CLIENTS" ]; then
      tmux switch-client -t "clikae-<tank>"
    fi
  else
    tmux_spawn_session --session "clikae-<tank>" …
  fi
  ```
  *(備註：`tmux_spawn_session`（`lib/core/tmux.sh`）是上述 Rule 1、2、4、5、7 的封裝函式，也是全 repo 唯一呼叫 `tmux new-session` 的地方。舊稿把它叫作 `clikae_spawn_session`，那個名字從未存在於程式碼。)*
  
  FIRES: 模擬含有空白的 tank 名稱
  ```
  $ bash -c 'tank="bad name"; case "$tank" in *[!a-zA-Z0-9_-]*) exit 2 ;; esac; echo OK'
  rc=2
  ```

### Rule 6: 無痕模式與排他鎖 GC (Ephemeral GC via lockf)
- **症狀**：斷線後無痕模式殘留，或 GC 因為誤用回傳碼而殺死無辜進程，或發生 unlink 競態。
- **收據**：
  - macOS 內建 `lockf`。不帶指令時必須使用 FD 形式。
  - `exec 9> lock; lockf -k -t 0 9` 回傳 0。持有中他人搶鎖回傳 `75` (EX_TEMPFAIL)。用法錯誤回傳 `64`。
  - 若在 `rc=0` 後執行 `rm -f lock`，可能剛好刪除到同名新任務的鎖檔 (TOCTOU)。
- **🔴 鎖檔必須放在私有目錄 `$HOME/.clikae/state`（0700），不可放世界可寫的 `/tmp`。**
  鎖名是可預測的（`clikae-ephem-<run_id>` / `clikae-ephem-slot-<cksum>`），放在 `/tmp` 時**別的本機使用者**可以：
  - 預先把它建成 symlink，讓我方的 `exec 9>` / `exec 8>` 沿著連結截斷受害檔（symlink-follow write）；
  - 投放一個 `clikae-ephem-<name>.lock`：它沒人持鎖，GC 判定為「dead」，於是把檔名當成 session id，
    **殺掉你的 tmux session `clikae-<name>`**、並 `rm -f` 你的 `$HOME/.clikae/state/<name>.*`——同機使用者
    對你活著的 session 與 state 的 DoS。
  私有目錄讓對方根本無從投放，同時避開 macOS 定期清 `/tmp` 造成的鎖檔消失。
  GC 另加 `case "$sid" in ''|.*) continue` 作縱深防禦。
- **規範**：
  無痕模式必須利用 shell redirect 與 FD，保持鎖的生命週期綁定在 client attach 期間（正常 detach 也會觸發 GC 刪除）：
  ```bash
  mkdir -p "$HOME/.clikae/state"; chmod 0700 "$HOME/.clikae/state"
  exec 9> "$HOME/.clikae/state/clikae-ephem-<run_id>.lock"
  lockf -k -t 0 9
  exec tmux attach -t "clikae-<run_id>"
  # 警告：exec 9> 與 exec tmux 之間，嚴禁任何 subshell 或關閉 FD 的操作
  ```
  清理巡邏程式 `clikae clean` 檢查鎖時，必須精確判斷 `rc==75`：
  ```bash
  lockf -k -t 0 "$HOME/.clikae/state/clikae-ephem-<run_id>.lock" true 2>/dev/null
  rc=$?
  if [ $rc -eq 0 ]; then
    # 搶鎖成功代表 FD 已釋放 (client 已斷開)
    tmux kill-session -t "clikae-<run_id>" 2>/dev/null
  elif [ $rc -ne 75 ]; then
    echo "ERROR: lockf failed with rc=$rc" >&2
  fi
  ```
  FIRES: 模擬搶鎖失敗
  ```
  $ bash -c 'exec 9> "$HOME/.clikae/state/ck-ephem-test.lock"; lockf -k -t 0 9; lockf -k -t 0 "$HOME/.clikae/state/ck-ephem-test.lock" true 2>/dev/null; echo $?'
  75
  rc=0
  ```

### Rule 9: 選取與複製 (Selection Is Part of the Deal)

- **症狀**：「clikae 支援 tmux 之後，我無法複製文字了。」（2026-08-15 回報）
- **診斷**：不是選不起來，是**構不到**。Rule 1 的 `*:smcup@:rmcup@` 關掉外層終端機的替代畫面（scrollback 擷取才有東西可擷），代價沒有人算過：
  ```
  $ tmux list-panes -a -F '#{session_name}: alternate_on=#{alternate_on}'
  ck-claude-h: alternate_on=1          # 內層 app 在用替代畫面
                                       # 但外層 Ghostty 被 smcup@ 擋掉了
  ```
  於是外層終端機的 scrollback 裝滿 tmux 的全畫面重繪殘渣，而乾淨的 50000 行歷史在 tmux 那邊、滾輪構不到。再加上：
  ```
  $ tmux show-options -s set-clipboard
  set-clipboard external      # tmux 預設：轉發 app 自己的 OSC 52，
                              # 但絕不為 tmux 自己的選取發一個
  ```
  ——所以就算進 copy-mode 複製，也只進得了 tmux 的 buffer，到不了 macOS 剪貼簿。
- **規範**：兩個選項跟 Rule 1 的其餘全域設定同一串下：
  ```bash
  set-option -g mouse on          # 滾輪捲 tmux 的真歷史；拖曳在裡面選取
  set-option -s set-clipboard on  # copy-mode 的 yank 走 OSC 52 進系統剪貼簿
  ```
  代價要講清楚：要用終端機**原生**選取（貼到 tmux 以外的地方）得按著 `⌥`。這是刻意換的——預設情境是「我要複製剛剛畫面上的東西」，那條路現在直通。

- **同一條全域鏈上另外掛著 touch-scroll 的六條 binding 與兩個選項**（`@clikae_touch_scroll`／`@clikae_touch_scroll_lines`，P3-4 2026-09 R2 review）——`mouse on` 讓滾輪捲得到歷史，touch-scroll 是同一個問題在沒有滾輪的觸控裝置（a-Shell/iPhone）上的另一半答案：把兩指觸控的按下/放開翻譯成同一段 `copy-mode` 歷史的捲動。裝載條件、tmux ≥ 3.1 的版本閘門、與清冊全文見 Rule 1；行為與 mode 的邊界（copy-mode/view-mode 才動作，tree-mode/clock-mode/choose-* 不動）見 `lib/core/tmux.sh`/`lib/core/touch_scroll.sh` 的行內註解與 `docs/usage.md`。

- 🔴 **附帶修掉一個累積型 bug**：`terminal-overrides` / `terminal-features` 是 **append**，而選項區塊每次建立 session 都跑，所以每 spawn 一次就多一份。實測兩天大的 server：
  ```
  terminal-overrides[1..4]   *:smcup@:rmcup@     ← 四份一模一樣
  terminal-features[3,5,6,7] xterm*:extkeys      ← 四份
  ```
  現在先查再 append。**這跟整層要防的是同一個形狀：把累積型操作當成冪等的來寫。**

### Rule 7: Server 出生時繼承的東西，之後補不回來 (Birth Inheritance)

- **症狀**：某個 tank 讀不到自己的 Soul，`Operation not permitted`。同一個目錄，換一顆 server 就讀得到。沒有彈窗、沒有任何錯誤訊息，只有 EPERM。
- **收據**（2026-08-15，真機）：
  ```
  $ # 同一台機器、同一個 uid、同一個目錄。stat 過得去，讀不出來。
  $ python3 -c "import os;os.stat('…/Vault/Soul/me')"     -> OK
  $ python3 -c "import os;os.listdir('…/Vault/Soul/me')"  -> errno 1 Operation not permitted

  $ # 四個受 TCC 保護的目錄全滅，非保護目錄正常 —— 這是 TCC 的指紋，不是 chmod 的
  $ ls ~/Documents ~/Desktop ~/Downloads "~/Library/Mobile Documents"  -> ×4 Operation not permitted
  $ ls ~/.clikae/souls/me                                              -> OK

  $ # 差別只在進程祖先
  launchd → tmux(17229) → bash → claude          讀不到
  Ghostty.app → login → zsh → bash → claude      讀得到

  $ # 而 tmux 從有授權的終端機起就會繼承 —— 所以 tmux 本身不是問題，出身才是
  $ tmux -L fdatest new-session -d 'ls ~/Documents > /tmp/out 2>&1'   # 在 Ghostty 裡下
  CELSYS / Documents - GoldenApple / d1-backups
  ```
- **規範**：
  1. Server 的身分——環境**和**檔案存取權限——在建立 server 的那一次 `new-session` 決定，之後任何 `set-option` / `set-environment` 都改不了。環境還能用 `-e` 逐一補；權限**沒有這個對應物**。
  2. 因此建立 server 只准有一個地方：`tmux_spawn_session`（`lib/core/tmux.sh`）。`tests/bats/roam.bats` 早就記下這件事的另一半——「everything else is inherited from the SERVER's process environment — which is whoever started the server, not us」——當時只把它推廣到環境變數。
  3. 建立時必須把出身寫下來，否則事後查不到：等你需要問的時候，parent 一定已經是 launchd。
     ```bash
     tmux set-environment -g CLIKAE_SERVER_BORN "<when> <tty|no-tty> <ancestry>"
     ```
     🔴 這條的代價是量出來的：PID 17229 究竟由互動路徑還是無人在場的 carry 路徑生出，**追不回來**——兩條留下的 tmux 命令列逐字相同。
  4. 啟動時偵測到 tank 讀不到自己的記憶，**大聲警告但照樣啟動**（與 Rule 2 的降級哲學一致：沒有記憶的 session 很糟，起不來的 tank 更糟）。判別式是兩個 syscall 的不對稱，**不是 errno**：

     | 量到的 | 意思 |
     |---|---|
     | `stat` 過 + 讀不過 | 路徑是對的，但讀不出來 —— 開火 |
     | bits 允許讀，而讀仍然失敗 | 檔案系統之上的東西擋的（macOS = TCC），指向 server |
     | bits 不允許讀 | 一般權限問題，講 chmod，**不要牽拖 tmux** |

     🔴 `[ -r ]` 走的是 access(2)，只看 bits，在 TCC 情境下會回答「可以」。**只有真的讀一次**才問得出真相。

  FIRES: bits 允許但讀不到（TCC 的形狀，用 stub 注入，因為 TCC 無法在測試裡合成）
  ```
  $ bats -f "names the tmux server" tests/bats/tmux-spawn.bats
  ok 1 memory probe: a read that fails while the bits allow it names the tmux server
  ```

  🔴 **對真 TCC 的收據**（2026-08-15，在那顆中毒的 server 裡跑，重開機後這個環境就不存在了）。合成的形狀跟真的一不一樣，只有這一次量得到：
  ```
  $ source lib/core/{log,tmux,soul}.sh
  $ memory_access_warn ~/.clikae/souls/me/memory      # → iCloud vault，真的被 TCC 擋著
  [ WARN ] this tank cannot read its own memory.
           memory: /Users/chodaict/.clikae/souls/me/memory
           cause:  the permission bits allow it and the read still failed.
           …
  $ memory_access_warn <一個讀得到的目錄>              # 正控
  （完全無輸出）
  ```
  走的是 TCC 分支而不是 EACCES 分支 —— 也就是說「stat 過 + bits 允許 + 讀失敗」這個判別式在真實條件下分得出來，不是只在 stub 下分得出來。

### Rule 8: 環境走檔案，不走 argv (The Environment Is Not a Command Line)

- **症狀**：`clikae burn` 把呼叫者的整份環境（`compgen -e`）當成 `-e KEY=VAL` 交給 `tmux new-session`。當這個 burn 正好是生出 server 的那一個，那串 argv 就變成 **server 自己的 argv**，活得跟 server 一樣久，而且 `ps` 對全機可見——包含 API key 與 token。
- **收據**（2026-08-15）：
  ```
  $ ps -o args= -p 17229          # 一顆前一天生出來的 server
  tmux start-server ; set-option -g history-limit 50000 ; … new-session -d \
    -e CLIKAE_TANK_NAME=claude-x -e HOME=/Users/… -e CLIKAE_HOME=/Users/…
                                  # 建立時的每一組 -e 都還在
  ```
- **規範**：
  1. `-e` 只放 session 層真正需要、且**不敏感**的少數幾個（`HOME`、`CLIKAE_*`、`CLIKAE_RUN_ID`）。
  2. 其餘一律寫進 burn 本來就會落地的 wrapper script。該檔**先建立、先 `chmod 0600`、再寫入**——不能有一個「已經有機密、還沒收權限」的視窗。
  3. 值用 `printf %q` 逸出（含換行的值也要能還原），名字非合法識別字的跳過，整段還原包在 `{ … } 2>/dev/null` 裡：還原環境本質上是 best-effort，readonly 變數在子行程失敗會弄髒 pane。

- **⚠️ 尚未收斂的部分（2026-08-15 有意留下，不是遺漏）**：
  `burn` 與 `switch` 現在共用**建構子**（`tmux_spawn_session`）與**傳輸規則**（機密走檔案不走 argv），但「要傳什麼」仍然不同：

  | | 傳什麼 | 為什麼 |
  |---|---|---|
  | `burn` | 整份環境 | 無人在場的引擎執行需要人類當時的 API key／proxy／PATH |
  | `switch` | 精選 3 個（`CLIKAE_TANK_NAME`／`HOME`／`CLIKAE_HOME`） | 歷史原因 |

  ⚠️ **本節前一版懷疑 `switch` 這一邊是 bug，說「精選清單以外的變數會拿到 server 的環境」。量過之後：不成立，已更正。**（2026-08-16，隔離 socket）
  ```
  # 先用「沒有 CK_PROBE_VAR」的 shell 建 server，再從「有」的 shell 開新 session
  新 session 看到: CK_PROBE_VAR=[from-second-shell-…]   ← 傳到了
  ```
  **建立新 session 時，tmux 繼承的是「下這道指令的 client」的環境**，不是 server 行程的。所以 `switch` 只傳 3 個 `-e` 沒有漏掉使用者的環境。
  真正改不了的是**已經在跑的 session**：那個引擎的環境在它啟動時就固定了，attach 回去不會刷新——那正是 Rule 4（SSH socket 用穩定 symlink）存在的理由，也是 `roam.bats` 那句註解在講的情況。兩者不是同一件事，把它們混為一談就會像我一樣去修一個不存在的 bug。

  所以剩下的差異只是**「傳什麼」**：burn 傳整份（無人值守需要人類當時的 key／proxy），switch 傳 3 個（其餘由 client 環境自然帶過去）。這是刻意的，不是漂移。

### Rule 10: 狀態列說的是「回來的指令」與「需要注意的事」(The Status Row, #77)

- **症狀**：每個 session 最下面那一行，從 v0.21 到 2026-09 一直是
  `[claude/hello] 0:claude* 1:wake … "✳ [ KITT ] tending th" 20:06 12-Sep-26`。
  它是產品裡**最持久可見的一個字串**（整個 session 都在螢幕上），而操作者每三十秒
  真正想知道的三件事——「怎麼回到這裡」「還剩多少油」「有沒有東西紅了」——一件都
  沒回答。視窗清單把 clikae 自己開的 `wake` 守望者當成使用者開的視窗露出來；標題被
  tmux 截到 20 欄；日期在你盯著它的時候不會變。
- **收據**（2026-09-14，tmux 3.4，拋棄式 socket `-S "$(mktemp -d)/sock"`）：
  ```
  # 1. #{} 在 #() 裡會被展開（這是整個設計的前提，不是假設）
  $ tmux set-option -t '=probe:' status-left \
        "#(bash probe.sh W=#{client_width} SID=#{@clikae_session_id} N=#{session_name})"
  $ # 117 欄的 client attach 之後，probe.sh 收到：
  args=[W=117 SID=a52bdc12-dead-beef-0000-111122223333 N=probe]

  # 2. 單引號包起來的空引數不會消失（引數數量才是對的）
  status-left "#(bash probe.sh 'a b' '' 'c' '#{client_width}')"   -> count=4

  # 3. 視窗清單要靠 status-format[0]，正反兩邊都量過
  設了 status-format[0] 的那一列： LEFTSEG-…                （沒有視窗清單）
  沒設的同一個 session：          LEFTSEG 0:sleep* 1:wake   （視窗清單在）

  # 4. helper 的成本（每次 20 連發，開發機 reefbox，16 核）
  閒置時              0m0.284s  ->  14.2 ms / 次
  load 6.15 時        0m0.612s / 0m0.331s / 0m0.415s  ->  16.6 ~ 30.6 ms / 次
  （30.6 那一次超出預算，所以把 burn 掃描僅剩的那個 $( ) 也拿掉：
    burn_status_dirsv 改成填陣列，整條路徑只剩 date 與 tmux 兩個 fork）
  拿掉之後，對著**活著的** tmux server（production 的條件），load 9.7~10.5：
                      0m0.298s / 0m0.346s / 0m0.471s  ->  14.9 ~ 23.6 ms / 次
  ```
  🔴 **這台機器不是中立的量測場**：上面每一組數字都是在同時跑著五條 sibling
  lane 的 reefbox 上量的，load 從 6 跑到 10。把它讀成「14 ms」是騙自己；誠實的
  說法是「閒置 14 ms、滿載 24 ms，預算 30 ms」，而且**超出預算的那一次是真的
  發生過**，不是雜訊——它就是拿掉最後一個 fork 的理由。成本的組成也量過：
  裸 bash 5.2 ms、加上四個 source 7.1 ms，其餘全是 `date` 與 `tmux show-options`
  這兩個 fork。
- **規範**：
  1. **這一列只在一個地方組出來**：`lib/core/tmux.sh` 的 `tmux_status_render`
     （內容）與 `tmux_status_line`（唯一寫 `status-left`／`status-right`／
     `status-interval`／`status-justify`／`status-format` 的地方）。`tmux_label`
     從此只負責視窗名稱，狀態列交給上面那個函式。
  2. **`#()` 那一端不做任何判斷**：`lib/core/status_line.sh` 只負責把
     `$HOME`／`$CLIKAE_HOME` 放到位、問 tmux 這個 session 在跑哪一份逐字稿
     （`live_session_id`）、然後呼叫 `tmux_status_render`。tmux 沒辦法自己重算一個
     shell 值，所以會變的東西（油量、警示、client 寬度）一定要走 `#()`；但**會變的
     只有值，不是規則**。
  3. **🔴 這條路上不准有 vendor、不准有網路、不准有 `jq`、不准有 `clikae` 自己。**
     tmux 每 5 秒、每個 attach 的 client 各跑一次，而且是在 tmux server 裡跑——一個
     會打網路的狀態列會永遠每五秒打一次，失敗了也沒有人看得到。油量只讀 #72 的快取
     檔 `state/usage/<engine>/<tank>.json`；讀不到就退回點，不是退回猜一個數字。
     `tests/bats/tmux-status.bats` 在 PATH 上放了會大聲失敗的 `curl`／`jq`／`clikae`
     樁，並斷言它們的 tripwire 檔沒有出現。
     固定成本只有兩個 fork（`date`、問 tmux 這個 session 的 id），而且那個 `date`
     由 `tmux_status_render` 呼叫一次、交給油量與警示兩邊共用——不只省一個 fork，
     也讓兩半不會對「現在幾點」有不同答案。

     🔴 P2-3（2026-09-14 round-1 fix review）：上面這句直到這次修正之前都是錯的。
     `dry_store_peekv`（警示那一半，掃 `$CLIKAE_HOME/dry/*/*` 每個乾涸標記各呼叫
     一次）內部用 `f="$(dry_store_path "$engine" "$tank")"` 重算路徑——一個
     `$( )`，每個標記一個 fork，跟標記數線性成長，不是「兩個」。
     `strace -f -e trace=clone,clone3,vfork,execve` 對真 helper（含 burn 那一半）
     跑一次 render，量到的 clone 數（這條 lane 自己的沙箱，隔離的 `TMUX_TMPDIR`，
     跟上面 14.2/24 ms 那組數字不是同一次量測，基線因此不同——量的是「隨標記數
     怎麼變」，不是絕對值）：

     ```
     dry marker 數   clone（修前）   clone（修後）
           0              12              11
           3              15              11
          33              45              11
     ```

     修前每多一個標記多一個 clone（+1/marker，跟先前 round-1 審查量到的斜率一致）；
     burn 那一半（`burn_status_dirsv`/`burn_status_fieldv`）完全不隨標記數變，
     fork-free 的部分本來就是真的。修法是把 `dry_store_path` 的函式本體
     （`printf '%s/dry/%s/%s\n' "$CLIKAE_HOME" "$1" "$2"`）直接內聯成
     `f="$CLIKAE_HOME/dry/$engine/$tank"`，不再透過會 fork 的函式呼叫——
     跟 `burn_status_dirs`／`burn_status_dir` 已經在用的「兩份字面值放同一段，
     好過其中一份是從另一份 derive 出來」是同一個取捨（見那兩個函式的註解）。
     `dry_store_mark`／`dry_store_read`／`dry_store_clear`／`dry_store_epoch` 仍然呼叫 `dry_store_path`——
     它們都不在 5 秒一次的熱路徑上，那個 fork 從來不是問題。

     🔴 P2-2（2026-09-14 round-2 review）：同一輪修正在三行外又加回一個 fork——油量年齡
     後綴寫成 `$(_human_age "$ca" "$now")`，一個包住 shell 函式的 `$( )` 就是一個
     subshell。同一個 strace 量法、真 helper、一次 render：快取剛寫 11 個 clone、
     **快取 2 小時前 12 個**（超過 1 小時是常態，不是邊角）。改成 `_human_agev suffix …`
     （`lib/core/duration.sh`，呼叫端傳變數名、函式用 `printf -v` 賦值，bash 3.2 可用、
     不用 nameref），修後兩者都是 **11**。`_human_age` 留成印出來的薄殼，給不在熱路徑上的
     board／resume 呼叫點。
  4. **🔴 這條路上也不准「寫」。** `dry_store_read` 順手刪掉過期標記對「問一次」的
     呼叫者是對的，對一個每五秒問一次的狀態列則會讓「這個標記什麼時候消失的」變成
     「剛好有沒有人在看狀態列」的函數。所以狀態列走 `dry_store_peekv`（唯讀孿生，
     同一條新鮮度規則），收垃圾留給真的在問的人。量過：把稽核範圍放大到整個
     `$HOME` 會紅，紅在 tmux 自己會建立 socket 目錄——那是 tmux 的家務事，不是
     clikae 的狀態。
  5. **警示 `!N` 只數已經存在的狀態，而且 N=0 時整段不畫**：
     `$CLIKAE_HOME/dry/<engine>/<tank>`（live catcher 寫的乾涸標記，
     新鮮度由 dry_store 自己的 TTL 決定），加上
     `$HOME/.clikae/logs/burn-*/status.json` 裡還寫著 `running`／`waiting-reset`
     但 pid 已經不在的那些（#41 對「沒走到終局、也就是沒有產物的 lane」的定義）。
     走到 `fail` 的**不算**：它當時已經對著跑它的人印過理由了，而這一列是為「還沒有
     人被告知」的事存在的。
     🔴 **CI 紅燈沒有被數進去，這是缺口不是決定**：issue #77 把它列為第三個來源，
     而這個 repo 唯一的 Stop hook（`scripts/harness-stop-hook.sh`）只把報告閘門的
     BLOCKED/ALLOWED 記進 `state/harness-hook.log`，從來沒有記過 CI 的判決。要數它
     得先發明那個狀態，那是另一個改動。（P2-2，2026-09-14 round-1 fix review：PR
     #102 本文曾經在這句話的反面下錯注——寫著「CI-red seen by the Stop hook」是
     `!N` 的來源之一，跟這裡、跟 CHANGELOG 都不一致。已經改成 PR 本文照這裡走，不
     是這裡照 PR 本文走：這段話本來就是對的，錯的是本文那一行。）

     🔴 **P2-1（同一輪 fix review）：死掉的 burn lane 現在會自己從計數裡消失，跟
     dry 那一半用同一個時鐘。** 修之前：一條被 SIGKILL（或 OOM、斷電）的 lane 最後
     一次寫的是 `running` 加一個已經不在的 pid，而在這之前，`!N` 會把它算進去——
     永遠，因為唯一會清掉它的是 `_burn_sweep_old_logs`（7 天、只在下一次
     `clikae burn` 才跑）。量過：`run dir` 的 mtime 改成 30 天前，紅燈完全不理會
     年齡。dry 那一半本來就有 `CLIKAE_DRY_TTL`（6 小時）讓一個沒人再看的標記自己
     退出新鮮度判定，燒的是 6 小時後轉綠而不是靠人手動清；燒那一半沒有這個。現在
     兩邊共用同一個常數：死 pid 的 lane 一旦 `updated_at` 超過 `CLIKAE_DRY_TTL`
     就不再計入 `!N`，跟 dry 標記變陳舊的判定同一把尺。
     **仍然存在、而且是刻意留著的不對稱**：dry 的標記檔本身會被下一次
     `dry_store_read`（不是 peek）懶惰刪除；burn 的 `status.json` 不會被這條讀路徑
     刪除——唯一會真的刪除它的仍然是 `_burn_sweep_old_logs`，7 天、只在
     `clikae burn` 才跑。兩邊現在在「算不算紅」這件事上同步了；「這份紀錄本身什麼
     時候從磁碟消失」仍然是兩條不同的路，因為 burn 的 `status.json` 除了
     alert-count 之外還有 `clikae wait` 這個真的需要它留著的讀者，不能像 dry 標記
     那樣隨便早刪。
  6. **🔴 不准有 emoji。** `scripts/signet-lint.sh` 對任何印出來的 emoji 都會紅
     （只放行 ❯ 游標），而這一列是印出來的。提案原本的 `🔴N` 因此不可能做；它是
     `!N`，顏色由 tmux 上。`○`／`·`／`│` 不在被掃的區段裡，而且 `○`／`·` 本來就是
     board 的字彙（`docs/DESIGN-board-fuel-dots.md`）。
  7. **寬度規則：會讓步的是 `ssh <host> -t ` 前綴，而且是整段拿掉不是截斷。**
     提案指定會截斷的那一段（session 標題）在同一串討論裡被第三次修正拿掉了，剩下
     唯一長度不固定的東西就是別人的主機名。半個主機名不是任何人跑得起來的指令，而
     `clikae resume a52bdc12` 在「你正在讀這一列的那台機器」上本來就完全正確。100 欄
     以下拿掉前綴，其餘最多 59 欄（量到：`clikae resume a52bdc12 │ 5h 100% · 7d 100% · 23h ago │ !10 `），
     80 欄永遠不截斷。
     🔴 P2-1（2026-09-14 round-2 review）：round 1 加的油量年齡後綴（`· 23h ago`，0 或
     9–10 欄）讓「其餘」也變成長度不固定，而前綴只看 `width >= 100` 決定——真 tmux 3.4、
     100 欄、30 字元主機名、快取 23 小時前，**被切掉的是時鐘**（`!10 8:31`），不是前綴。
     規範不改，改的是碼：`tmux_status_render` 先組好油量與警示，**只有在整列加上前綴之後
     仍然留得下時鐘的 6 欄（`%H:%M `）時才加前綴**。同一台、同一寬度、只換快取年齡量過：
     29 字元主機名＋後綴 → `… !10 18:32`（前綴留著、時鐘完整）；30 字元 → 前綴整段拿掉、
     時鐘完整；120／80 欄行為不變。
  8. **左邊那一段要真的是一道可以貼上去的指令**：有逐字稿 id 就是
     `clikae resume <8 碼>`（所以 `clikae resume` 必須接受唯一前綴——
     `_resume_prefix_candidates`，同一次改動的另一半，模稜兩可就列出候選並拒絕）；
     沒有 id（codex／antigravity 的裸啟動，見 `tmux_set_session_id`）就是
     `clikae <engine> <tank>`，絕對不是裸的 `clikae resume`——那會開選單，不是回到
     這裡。
  9. **主機名在 clikae 自己的行程裡解，不在 helper 裡解**：`#()` 是 tmux **server**
     的子行程，繼承的是當初啟動 server 的那個環境（可能是好幾天前的另一個 shell）。
     `tmux_status_line` 跑在人類真正坐著的那個 shell 裡，所以那裡的
     `$SSH_CONNECTION` 才真的代表「這次啟動是從 ssh 進來的」。這是證據不是證明，而
     它往安全的方向偏：不知道主機名就顯示不帶前綴的指令，那在讀這一列的地方永遠是
     對的。`$CLIKAE_HOST` 一律優先——一台機器自己叫自己的名字，常常不是外面解得到的
     那個名字。
  10. **不要用 `window-status-format ''` 來藏視窗清單。** 它是**視窗**選項：用
      `-t "=$session:"` 只會打到那個 session 的**當前**視窗，於是稍後才被
      `wake_attach_watcher` 開出來的 `wake` 視窗又會帶著預設值回來；改用 `-g` 則會
      把整台 server 上每一個 session（包含人類自己開的）的視窗清單清掉。
      `status-format[0]` 是 **session** 選項，換掉的是整列，視窗清單包含在內。
  11. **沒有 fleet 那一段**（提案裡的 `reefbox x● hi● l○`）。同一串討論第三次修正
      把它撤掉了：整支艦隊的逐槽油量住在 board（`clikae home`，#72 之後是真數字），
      狀態列講的是**這一槽、這一個 session**。`tests/bats/tmux-status.bats` 有一條
      測試守著這個「沒有」，所以哪天要加回來會是有人刻意做的決定。
