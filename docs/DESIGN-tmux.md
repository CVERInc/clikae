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

- **每 session（非全域）的 clikae 選項清冊**：`status-left` / `status-left-length` / `status-right` / `status-right-length` / `status-interval` / `status-justify` / `status-format`（全部在 `tmux_status_line`，2026-09 #77 之前只有前兩個、且在 `tmux_label`；見 Rule 11）之外，2026-09 起新增 `@clikae_session_id`（`tmux_set_session_id`，`lib/core/tmux.sh`）—— clikae 寫進 tmux 的第一個 per-session 使用者選項，記錄「這個視窗當初是為了哪個逐字稿 session id 開的」，`live_session_id`（`lib/core/live.sh`）讀回。與上面的全域選項不同，它是單一 session 作用域、`set-option -t "=$session:"`，不會漏到同一 server 的其他 session；但同樣只在 `tmux_spawn_session` 剛建立的那個 session 上寫，且只在真的 spawn（非 attach）時寫——Rule 7 的「出生時繼承」對它不適用（它不是 server 出生時決定的，是每次 spawn 各自決定的），但同一個道理仍然成立：寫的時機只有一個地方，讀的時候永遠先查 option、查不到才退回 `~/.clikae/state/<session>.session_id` 鏡像檔。

- **`base-index` 是全域選項，clikae 從來沒有設過它，讀的一方不能假設它是 0**：2026-09 起 `live_engine_alive`（`lib/core/live.sh`）需要問「這個 session 的引擎視窗還在不在」，一度用 `tmux list-windows -F '#{window_index}'` 比對字面 `0`——跟這條規則本身講的道理正是同一件事（`history-limit` 那個收據）：`tmux_spawn_session` 沒有設 `base-index` 不代表它是 0，代表它繼承使用者 `~/.tmux.conf` 裡設的任何值，而 `set -g base-index 1` 是很常見的一行。在 `base-index 1` 的機器上，引擎唯一的視窗落在 index 1，字面比對 0 因此把每一個健康 session 都判成「引擎已死」（2026-09-12 R4 review, R4-P2-1）。修法改問視窗**名稱**：是否存在一個不是 `wake` 守望者（`^wake( |$)`，`wake_attach_watcher` 開的那個）的視窗——與 `tmux_sess_has_engine`（`lib/core/tmux.sh`）同一個問法，同一層已經有正典答案。任何要問「這是不是某個特定視窗」的呼叫點，一律用名稱或這個 per-session 選項，不用數字位置。

- **2026-09 起新增十二條全域 key binding ＋ 五個全域選項（touch-scroll，P3-4 2026-09 R2 review；tap zones 與 drag，#108）**：`bind-key -T root/copy-mode/copy-mode-vi` 的 `MouseDown1Pane`／`MouseUp1Pane`／`MouseDrag1Pane`／`MouseDragEnd1Pane`（十二條，`lib/core/tmux.sh` 的 touch-scroll 區塊）與 `@clikae_touch_scroll`／`@clikae_touch_scroll_lines`／`@clikae_touch_pages`／`@clikae_touch_pages_rows`／`@clikae_touch_drag`（`set-option -og`）。**tap zones 沒有自己的 binding**：#108 的 tap zones 跟 #88 的 swipe 共用同一組 MouseDown/MouseUp，判斷全部收在 `lib/core/touch_scroll.sh` 一棵決策樹裡（先位移、再 zone、其餘不動）——同一顆按鍵綁兩次的話 tmux 只留最後一條，輸掉的那個功能會安靜地消失。MouseDown 因此多寫一個 pane 選項 `@clikae_touch_h`（`#{pane_height}`，按下當時的幾何），跟 `@clikae_touch_y` 一樣讀完立刻 unset。**drag／dragEnd 那六條則是真的新按鍵**（2026-09-16 真機量測：a-Shell 的滑動只送 motion、不送 MouseUp，詳見 Rule 9），而且是**唯一**走 `if-shell` 而非 `run-shell` 的一組——離開狀態非 0 時把按鍵原封不動還給 tmux 自己的指令，這就是 `@clikae_touch_drag off`（預設）等於原生 tmux（含拖曳選取）的全部機制。跟 `history-limit`／`mouse on` 同一條鏈、同一個作用域（整台 server，不是這個 session），但多一層閘門：`_tmux_touch_scroll_floor_met` 要求 **tmux ≥ 3.1**（`set-option -p`/`-pu`，CHANGES FROM 3.0 TO 3.1）——低於這個版本，`mouse on` 照裝，這六條 binding 與兩個選項整串跳過（不是裝一半，見 Rule 1 開頭 `history-limit` 那條「串在同一個指令」的規範）。`bind-key` 沒有 `-o`，會覆寫使用者自己在 root table 上已經設過的 `MouseDown1Pane`/`MouseUp1Pane`（`docs/usage.md` 已寫明）。細節、每個 binding 的理由、以及 choose-mode/clock-mode 的邊界見 `lib/core/tmux.sh` 本體的行內註解（Rule 9 收 `mouse on`/`set-clipboard` 那兩個更早的全域選項）。

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

- **同一條全域鏈上另外掛著 touch 的十二條 binding 與五個選項**（`@clikae_touch_scroll`／`@clikae_touch_scroll_lines`，P3-4 2026-09 R2 review；`@clikae_touch_pages`／`@clikae_touch_pages_rows`，#108；`@clikae_touch_drag`，#108 後半——後三個**預設 off**，理由都一樣：它們把原本會送到程式或會做選取的那一下改交給 tmux，所以要人家開口才給）——`mouse on` 讓滾輪捲得到歷史，touch-scroll 是同一個問題在沒有滾輪的觸控裝置（a-Shell/iPhone）上的另一半答案。裝載條件、tmux ≥ 3.1 的版本閘門、與清冊全文見 Rule 1；行為與 mode 的邊界（copy-mode/view-mode 才動作，tree-mode/clock-mode/choose-* 不動）見 `lib/core/tmux.sh`/`lib/core/touch_scroll.sh` 的行內註解與 `docs/usage.md`。

- 🔴 **2026-09-16 真機量測推翻了 #88 的前提，而這條規則的「選取」正是它撞上的東西。** 用 a-Shell → ssh → tmux 3.4、在伺服器端被動記錄事件流，量到的是：
  ```
  輕點 (tap)        MouseDown1Pane + MouseUp1Pane（同一列）
  滑動 (flick/drag) MouseDown1Pane + 每跨一列一個 MouseDrag1Pane + MouseDragEnd1Pane
                    ——完全沒有 MouseUp1Pane
  ```
  #88 把整套翻譯掛在「MouseUp 帶位移」上，所以在它所為之而寫的那台裝置上**一次都沒觸發**；贏的是 tmux 自己的 `MouseDrag1Pane → copy-mode -M` 與 `MouseDragEnd1Pane → copy-pipe-and-cancel`，使用者看到的是 “copied N chars to tmux buffer”——**本規則的選取行為**，出現在他想捲動的時候。
  四件必須記在這裡的事實：
  1. **drag 的六條 binding 走 `if-shell` 而不是 `run-shell`。** `run-shell` 丟掉離開狀態，所以用它蓋的 binding 只會「吃掉」按鍵。`MouseDrag1Pane` 在沒有 mouse-tracking 程式的 pane 上的原意就是**滑鼠拖曳選取**，而手指的拖曳跟觸控板的拖曳是**同一組 tmux 事件**，沒有任何 runtime 訊號分得出來。因此由 helper 的離開狀態決定：0＝clikae 翻譯了，非 0＝跑 tmux 自己的那條指令（else 分支是從 `tmux -f /dev/null` 的 `list-keys` 逐字抄回來的）。`@clikae_touch_drag off` 因此不是「近似預設」，它**就是**預設，含拖曳選取。（已驗證 mouse event 進得了 if-shell 的分支：一條 shell 指令回傳 1 的 binding，確實對著真正的按下跑出了 `copy-mode -M`。）
  2. **替代畫面的 app 拿到的是滾輪，不是 copy-mode。** 量到 Claude Code 的 pane 是 `alternate_on` 1、`history_size` 0——copy-mode 在那裡沒有東西可捲。它要的是滑鼠滾輪，而且它本來就在要。
  3. 🔴 **`tmux send-keys -t <pane> WheelUpPane` 不會送出滾輪事件，它會把那個「字」打進去。**（丟棄式 server、pane 跑 `cat -v` 驗過：app 讀到的是字面上的 `WheelUpPane`。）tmux 的滑鼠鍵名是給 `bind-key` 用的，不是給 `send-keys` 用的。要送的是終端機自己會送的那串原始 SGR：`ESC [ < Cb ; Cx ; Cy M`，`Cb` 64＝滾輪上、65＝滾輪下，座標 1-based。
  4. 🔴 **`#{pane_mode}` 在不在 mode 裡時展開成空字串**——不是佔位符，是什麼都沒有。在 `run-shell`／`if-shell` 的參數列裡沒加引號的話，它產生的不是一個空參數而是**沒有參數**，後面每一個都往左移一格。#88 之所以躲過，只因為 `#{pane_mode}` 是它的最後一個參數；drag 那兩行後面還有兩個，所以五個格式參數**全部加引號**。
  5. a-Shell 自己的長按選取不受 tmux mouse mode 影響，所以在手機上把 `MouseDrag1Pane` 讓給捲動不會失去選取；雙指滑動則被 a-Shell 自己吃掉、變成方向鍵，根本到不了 tmux。

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

### Rule 10: tmux guard shim（inherited $TMUX 不可被裸命令殺掉，CVERInc/clikae#97）

- **症狀**：一個從 clikae 啟動、因而繼承了 `$TMUX` 的行程，跑了一個**沒指名 socket／session** 的毀滅性 tmux 指令，殺掉的是繼承來的那顆 server，不是它以為自己在隔離的那個。
- **收據**（兩起，同一個形狀）：
  ```
  2026-09-10  一個 reviewer 下了裸的 `tmux kill-server`（沒有 -L），
              打掉了 operator 真正的 server。

  2026-09-13  一條 fix lane 跑 TMUX_TMPDIR="$T" tmux kill-server，
              以為 TMUX_TMPDIR 隔離了自己。Socket 優先序是
              -S > -L > $TMUX > TMUX_TMPDIR，而 $TMUX（從座艙繼承）
              有設，所以打中的是座艙——連同 14 條正在跑的 lane，
              一起死掉。同一條 lane 從自己的逐字稿被 resume 之後，
              31 分鐘內用同一個形狀又做了一次。
  ```
  兩次同一個形狀，不是意外：`TMUX_TMPDIR` 從來不隔離「已經繼承 `$TMUX`」的行程，因為 tmux 的 client 一律先問 `$TMUX`。
- **規範**：
  1. `lib/shims/tmux`（bash 3.2）只在 `$TMUX` 有設的時候開火。擋兩個動詞，且不只認字面字串——tmux 自己接受**唯一前綴縮寫**，所以 `kill-serv`／`kill-ses`（≥6 字元、真的是該動詞的前綴）跟打滿全名一樣被擋；掃描時跳過**帶值的全域選項**（`-c`／`-f`／`-L`／`-S`／`-T`，各自吃掉下一個 token）避免動詞槽被偷走；`\;` command list 的**每一段**都各自檢查，不是只看第一段。沒帶 `-S`/`-L` 的 `kill-server`（會殺掉整顆繼承來的 server）、沒帶**有值的** `-t` 的 `kill-session`（會殺掉繼承來的**當前** session）。rc 86，訊息點名那個 socket 和合法寫法。`$TMUX` 沒設時（一個人在乾淨的 shell 裡）什麼都不擋——這不是「更安全的 tmux」，是「只在會撞到別人 server 的那個形狀上開火」。**這個判斷完全不需要解出真正的 tmux 在哪**，argv 和 `$TMUX` 就夠，所以它在下面第 2 點的 PATH walk 之前就先跑（clikae#97 review round 1, P2-2：macOS CI 沒有 tmux，refusal 判斷因此不依賴它是否存在）。🔴 `-S`/`-L`/`-t`/`-a` 的判定是**逐 segment**的，不是掃一次整份 argv（clikae#97 review round 2, P2-2）：早一版一次掃完整份 argv，於是 `capture-pane -S -3 -p \; kill-server` 裡 capture-pane 自己的 `-S`（一個起始行號，跟 socket 無關）會替後面那段 `kill-server` 的守衛開後門，`list-panes -t x \; kill-session` 同理靠別的命令的 `-t` 放行；一個**黏在前一個字上的 `;`**（`tmux ls\; kill-server`，shell 交給 shim 的是單一 token `ls;`）也要跟獨立的 `;` token 一樣結束一段——tmux 自己的 parser 兩種都當成段落邊界，早一版只認後者。三筆都真的殺掉過一顆拋棄式 server。🔴 **target 算的是值，不是旗標**（clikae#97 review round 3, P2-B）：早一版只要看到 `-t` 就當成指名了，於是 `kill-session -t ''` 放行——tmux 拿到空的 target 會自己挑一個 session 殺，實測兩個 session 時殺掉的是**另一個**，只有一個 `clikae-` session 時整顆 server 跟著死。腳本裡寫 `tmux kill-session -t "$SESS"` 而 `$SESS` 沒設，交出來的正是這個 argv。現在 `-t ''`、`-t ""`、`-t` 是一段的最後一個 token、`-t=`、單獨一個 `=`（tmux 的精確比對前綴、後面沒有名字）全部算「沒有 target」，rc 86。🔴 **帶值的全域選項表釘死在 tmux 3.4 的 usage 上，新版 tmux 若新增帶值全域選項，失效方向是放行**（clikae#97 review round 4, P3-新1）：早一版把每一個看不懂的 dash 選項都當成「不吃值」，於是一個(未來的、tmux 3.4 沒有的)帶值全域選項——好比假想的 `-X val`——會讓它自己的值 `val` 頂替掉動詞槽，緊接在後面的真正動詞（例如 `kill-server`）反而被當成那個假動詞的參數，從沒被檢查過：實測 `tmux -X val kill-server` 放行、殺掉一顆拋棄式 server。tmux 3.4 本身沒有這個洞（它的全域選項 usage 就是帶值 `-c`／`-f`／`-L`／`-S`／`-T`、不帶值 `-2CDlNuVv` 兩張表，這張表逐字核對過完全吻合，`-X` 這種 tmux 自己會先報 `unknown option`）——這一條只防未來版本。現在的分野是：只有**明確列在這兩張表裡**的才算「認得」；任何其他 dash 開頭、還沒找到動詞的 token 都算「不認得」，此後放棄猜動詞槽，改成對這一段**逐 token 位置無關地**掃 `kill-server`／`kill-session`（或其 ≥6 字元前綴）有沒有出現過，出現就擋（`-t`／`-a` 的追蹤本來就不依賴動詞是不是真的，繼續有效，所以「`kill-session` 但有指名 target」的豁免不會跟著遺失）。不認得的選項本身**不是**被擋的對象——`tmux -q -V` 這種沒有任何禁字的呼叫照樣放行；只在放行方向失效的那兩個動詞上才 fail-closed。🔴 **叢集短選項裡的 `t` 現在也算指名**（clikae#97 review round 4, P3-新2）：kill-session 自己的短選項 `-a`／`-C`／`-t` 可以像任何 getopt 風格一樣黏在同一個 token 裡，tmux 待它跟單獨的 `-t` 一樣——但早一版只認得 `-t`／`-t*`（值黏在 `t`後面，例如 `-ta`／`-tcur`）跟 `-a`／`-aC`／`-Ca` 三個字面組合，`t` 排在其他字元**後面**時（`-at`、`-Ct`、`-aCt`）完全沒被認出來，於是 `kill-session -at cur` 明明指名了 `cur` 卻被擋、訊息還說沒有指名。現在任何以字面 `t` 結尾、且不是單獨 `-t`／`-t=`（兩者已經各自處理）的 token 都當成「下一個 token 是這個 `-t` 的值」。
  2. 它找真正的 tmux 是**走 PATH、跳過自己的目錄**（用檔案 identity 比對，不是硬寫 `/usr/bin/tmux`）。第一跳單純跳過自己、拿第一個非自己的候選——不管它是不是 script——這樣單一 guard 前面接的東西（另一個 guard、或測試自己裝的假 `tmux`）都照常被 exec 進去，跟 #97 之前的行為一模一樣。只有偵測到**繞回自己**（用一個會 export、每跳一次加一的計數器 `_CLIKAE_TMUX_SHIM_HOPS`，第二跳以上才算；值是 `<pid>:<n>`，只在 pid 是自己或自己的父行程時才採信，理由見第 3 點末尾；舊格式的裸數字、`garbage`、超出範圍的值一律當成沒設，不會讓 shim 在 `set -u` 底下中止）才會改成跳過 script 候選、只認編譯過的二進位檔——真正的 tmux 永遠是二進位檔，這條讓它不必認得某個特定 guard 的名字，就能在真的形成環的那一刻跳過「另一個 guard」直達二進位檔（`tests/stubs/tmux-guard` 同款識別技巧）。🔴 早一版直接「一律跳過所有 script」，結果連 `tests/bats/burn.bats` 自己裝的假 `tmux`（單一 guard 之後、沒有第二個 guard 會反彈回來）也被跳過，變成安靜地打真正的 tmux 而不是測試預期的那個 stub——這正是「規則本身」與「規則要解決的那個現象」被搞混的例子，計數器只在真的偵測到環時才升級,才不會連累正常的單層組合。找到候選之後**原封不動 exec，不改交出去的 `$PATH`**——早一版會把自己的目錄從交出去的 PATH 上剝除，理由是「這樣下游就永遠找不到我」，但那連帶剝掉了下面第 3 點唯一真正生效的管道，讓守衛安靜地變成裝飾品（P1-1，同一輪複審）。計數器只在確認交出去的目標是**二進位檔**時才 `unset`——若還沒 unset 就把它剝掉，下一跳讀回的又是「沒設過」，等於每一跳都重新從 0 算起，環永遠不會被偵測到（第一版就是這樣、實測會真的卡死，不是理論風險）。全部都是 script、完全沒有二進位檔可選時（例如測試用的 recorder stub），退而求其次選第一個非自己的候選，而不是直接 127。🔴 **這個退而求其次也需要一個硬上限**（clikae#97 review round 2）：shim 跟另一個 self-skip guard 互相接力、PATH 上完全沒有二進位檔可選時，兩邊都認不出彼此不是「真正的 tmux」，會永遠彈來彈去——實測沒這個上限會彈 5040 次才被外部 timeout 砍掉。超過 4 跳就直接回 127（`gave up after N hops`），什麼都不殺，跟下面「PATH 上完全沒有真正 tmux」走同一條安全失敗路徑。判斷候選是 script 還是二進位檔用 bash 內建 `read -r -n 2`（讀檔案前兩個位元組跟 `#!` 比對），不是 `$(head -c 2 …)`——`head` 本身要透過這個 shim 正在檢查的那條 PATH 才解得開，PATH 上完全沒有 coreutils 時 `head` 找不到、`$(…)` 回傳空字串，被讀成「是二進位檔」，於是每一跳都把計數器 unset 掉，上限永遠算不到（跟前一段「早一版連 unset 時機都錯」是同一種病，只是觸發條件不同）。
  3. 🔴 **守衛真正落地靠的是 pane 自己的啟動指令，不是 `-e`**（P1-1，同一輪複審）。`tmux(1)` 的「GLOBAL AND SESSION ENVIRONMENT」白紙黑字寫著新行程的環境＝**server 出生時凍住的全域表**疊上**session 表**（只有 `-e`／`set-environment`／`update-environment` 會動它）——但實測（隔離 socket，不牽扯 clikae）：一個 pane 的**真實行程**拿到的其實是**下指令那個 client 當下的 `$PATH`**，`-e PATH=…` 對它來說只是裝飾。所以 `tmux_spawn_session`（`lib/core/tmux.sh`）疊好 `$PATH`（shim 目錄疊在最前面，冪等）之後，把 pane 的**啟動指令本身**包成 `env PATH=<疊好的值> <原指令>`——這是 pane 自己的第一個 exec，不管 tmux 怎麼處理環境表都繞不過去。`-e "PATH=…"` 仍然保留（`tmux show-environment -t` 讀得到），但只是文件用途，沒有任何機制再依賴它。同一步也疊一次自己行程的 `$PATH`（冪等，圖的是這個函式接下來自己呼叫的每一個 `tmux` 也順便走 guard）。四個呼叫端（switch ×2、burn、relay/antigravity）都經過這一個建構子，全部免費拿到；`burn` 另外有自己的坑（第 6 點）。🔴 同一步也用 `env -u _CLIKAE_TMUX_SHIM_HOPS` 把跳數計數器從 pane 自己的啟動指令上剝掉（clikae#97 review round 2, P2-1）：第 2 點的計數器要活過 shim 交給一支 SCRIPT 的那一跳（它可能反彈回 shim），但那支 script 沒有義務在自己接下來 exec 進真正的 tmux 之前清掉它——實測 `~/.local/bin/tmux` 這樣的 host guard 就真的把它原封不動帶進了一顆真正的 server。那顆 server 一旦是這樣生出來的，計數器就凍進它的環境，此後這顆 server 上**每一個**新 pane 一出生就帶著 `HOPS=1`，第一次呼叫 `tmux` 就直接進入「偵測到環」模式——PATH 的保證用同一招修過（P1-1），這裡是同一個機制的第二次使用。🔴 **但這一招只管得到 `tmux_spawn_session` 親手開的那一個 pane**（clikae#97 review round 3, P2-A）：`new-window`、split、prefix+c、以及 clikae 自己的 wake 視窗（`lib/core/wake.sh`）都是從 server 的全域表繼承環境，不經過這條啟動指令。實測：經由 script wrapper 出生的 server 上，`new-window` 開的 pane 一出生就是 `HOPS=1`，第一次呼叫 `tmux` 就跳過 wrapper；wrapper 是 host guard v3 的時候，在那個 pane 裡 `unset TMUX; tmux kill-server` **直接殺掉了 server**（rc 0）。真正的修法在 shim 本身（第 2 點）：計數器存成 `<pid>:<n>`，只有**同一個 pid**（exec 鏈保留 pid，正是互相接力的形狀）或**它的直接子行程**（wrapper 用 fork 而不是 exec 呼叫 `tmux`，也照樣要撞到上限）才採信。server、pane、pane 的子行程都是別的 pid，凍進 server 的那份值因此對每個 pane 都等於沒設。`env -u` 保留，不花成本、讓 pane 的環境保持乾淨，但不再是這個保證的來源。已知殘留：(a) 用 `tmux -D`（server 不 daemonize、就是那個 client 自己的 pid）經過 script wrapper 起的 server，它的 pane 的父行程正好是計數器記的 pid，會被採信一次；(b) pid 回收：記下的 pid 死掉後剛好被某個 pane 或它的父行程重新拿到。兩者的後果都只是「第一次呼叫當成第二跳、跳過 script wrapper」，拒絕判斷（第 1 點）不看計數器，照樣先跑。
  4. `clikae doctor`（`_doctor_tmux_guard`）讀每個活著的 clikae session **pane 行程自己的真實環境**（Linux：`/proc/<pane_pid>/environ`；macOS：`ps eww -p <pid>`），不是 `show-environment`（P1-2，同一輪複審：寫入與讀回同一張表，對任何真的經由 `tmux_spawn_session` 出生的 session 結構上不可能紅）。回報 shim 目錄不在最前面的——**有裝跟裝在第一位是兩件事**，這個守衛只在第一位時才是真的。舊 session（守衛上線前就 spawn 的）不會自己補上：要重開那個 tank。🔴 macOS 分支（`ps eww`）在這一輪之前**從沒被任何平台真的跑過**（GitHub 的 macOS bats runner 沒有 tmux，這個函式自己的 `command -v tmux` 就先短路；Linux 一律走 `/proc`）——`ps eww` 先印命令、後印環境，而 Rule 10 自己把 pane 的啟動指令寫成 `env PATH=… <cmd>`，所以命令列上合法地就有一段字面上的 `PATH=…`，在它之後才是這個行程真正的環境；舊版取**第一個** `PATH=` token，抓到的正是命令列那段裝飾，現在改抓**最後一個**。這兩個探針也都套了 `|| true`（跟 `lib/core/proc.sh` 同一個 LOAD-BEARING 理由）：doctor 整支在 `set -eo pipefail` 下跑，一顆剛結束的 session 讓 `list-panes` 回非零、或環境讀不到，舊版會讓整份健檢中途死掉，不只是這一條探針空白。🔴 **「讀不到」跟「沒有守衛」是兩個答案**（clikae#97 review round 3, P3-4）：pane 行程已經結束、`list-panes` 失敗、`/proc/<pid>/environ` 讀不到（或 macOS 的 `ps` 失敗、印不出 PATH），以前全都被歸進「not first on PATH」再加一句「restart the tank」，等於替一個根本沒看到的 session 下判決。現在 `_doctor_pane_path` 讀不到就回非零，這幾種情況另外印一行 `unknown, could not verify: <sess>`，只說「沒能確認」，不叫人重開。
  5. reefbox 上暫時的 host-level guard（`~/.local/bin/tmux`，同一套邏輯，寫死 `/usr/bin/tmux`）**還不能退役**——P1-1/P1-2 修好之前，這個 shim 從未真的把守衛裝到 pane 行程上過，實際擋著座艙的一直是那個 host guard。🔴 一支「二進位檔前面擋著一支 script wrapper」的形狀（host guard 正是這個形狀）本來就是第 2 點的 hop resolver 認得的候選：第一跳把它當成一般候選、`exec` 進去，不成環——因為它硬寫死了 `REAL=/usr/bin/tmux`，不會反彈回來（跟真正的兩個 guard 互相接力是不同的事）。但硬寫死同時也代表：**只要 host guard 排在前面，這個 shim 就永遠不會被諮詢到**——兩個守衛不會疊加、不會互相補位，誰在 PATH 上先開火就只有那一個的邏輯生效，另一個永遠看不到那一發（clikae#97 review round 2, 實測 `kill-serv`（host guard 不認的縮寫）在 host guard 排前面時真的殺掉了一顆 server；shim 排前面時擋下）。**退役的判準是「誰的 PATH 上有這個 shim」，不是「shim 上線了沒」**：shim 只存在於 `tmux_spawn_session` 親手疊出來的那條 PATH 上，座艙自己的外層 shell、ssh 登入、cron、systemd、手動開的 lane——PATH 上都沒有它，退役 host guard 這些 shell 就一個守衛都沒有。只有「被一顆帶著這一輪修好的 shim 的 clikae 重新 spawn 出來的 pane」才真的受它保護——**座艙本身要先被這樣重開一次**，退役才安全；在那之前兩個都留著。
  6. **這個守衛不覆蓋的範圍**，全部是設計如此，不是漏掉：
     - `unset TMUX; tmux kill-server`——`$TMUX` 沒設就不開火，因為守衛只管「撞到繼承來的 server」這個形狀。reefbox 上沒有 `$TMUX`／`-S`／`TMUX_TMPDIR` 時的預設 socket**就是座艙那顆**，所以帶著 `unset TMUX` 的拋棄式 socket 寫法（本專案 fix lane brief 教的那種）本身要正確才安全，守衛不替它兜底。
     - 絕對路徑呼叫 `/usr/bin/tmux`、或某個 shell function／alias 把 `tmux`遮住——守衛靠 PATH 解析，繞過 PATH 解析就繞過守衛。
     - **夾在另一個命令參數裡的 tmux 命令**（clikae#97 review round 3, P3-3）：shim 只看 argv 上每一段的動詞，不會打開別的命令拿來當參數的命令字串再解析一次。會夾帶命令的有 `if-shell`、`run-shell`、`source-file`（檔案內容）、`confirm-before`。實測（`$TMUX` 有設、拋棄式 server）：`tmux if-shell -F 1 kill-server` rc 0，**server 死掉**；`tmux source-file <內容是 kill-server 的檔案>` 同樣 rc 0、server 死掉；對照組裸的 `tmux kill-server` 同一個環境下 rc 86、server 活著。要擋這一類得在 shim 裡重做一份 tmux 的命令解析器（含 format 展開與 shell 字串），這不在守衛的目標裡；它擋的是「以為指名了、其實沒有」的裸指令，不是刻意把命令包起來的寫法。
     - `kill-session -t <自己當前 session 的名字>`——合法但自殺式；帶著**一個有名字的 target**（a named target）就是「你指名了」，指名的就放行，這正是「命名你的目標就是全部要求」那條哲學,不在守備範圍。空的 `-t`（`-t ''`、`-t=`、`-t` 後面沒東西）什麼都沒指名，不算豁免，照樣擋（第 1 點）。
     - `kill-pane`／`kill-window`——爆炸半徑留在單一 session 內，不會帶走別的 lane，同樣不擋。🔴 副作用留一筆：一顆 server 上只剩一個 session 時，殺掉它最後一個 pane 會讓那顆 server 自己跟著結束（tmux 的 `exit-empty` 預設）——「不會帶走別的 lane」還是成立，但「爆炸半徑留在單一 session 內」不等於「這顆 server 沒事」。
     - PATH 上完全沒有真正的 tmux（也沒有任何 script 可以退而求其次）——回 127，什麼都沒殺，安全方向的失敗。
  7. **已知、寧可多擋的缺口，排在 #106 後續處理**（clikae#97 review round 3, P3-1／P3-2；兩者都是安全方向的失敗，不會放行任何 kill）：
     - `kill-session -C`（只清 alert、不殺任何東西）照樣被擋，`-C`／`-aC`／`-Ca`／`-a -C` 全部 rc 86。`-aC` 的訊息還說它「kills every OTHER session」，帶 `-C` 時這句不對。
     - PATH 裡的**空項**（代表 `.`，例如 `PATH="<shim>:"`、`"<shim>::/x"`）被跳過，不會被當成目前目錄：cwd 裡有 `tmux` 也回 127。明寫 `<shim>:.` 就找得到。

### Rule 11: 狀態列說的是「回來的指令」與「需要注意的事」(The Status Row, #77)

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

  🔴 **P3-3（2026-09-14 round-3 review）：上面那組數字是用 load 表達的，而真正的
  自變數是 run dir 的「數量」。** load 是這台機器當下的雜訊，run dir 數是這一列
  自己的輸入——`tmux_status_alertsv` 對 `$HOME/.clikae/logs/burn-*` 每一個目錄開一次
  `status.json`，成本跟目錄數線性成長，而目錄只會單調累積：保存期 7 天，但
  `_burn_sweep_old_logs` **只在有人跑 `clikae burn` 時才掃**，所以一台「開著 tmux
  但這週沒 burn」的機器不會自己變便宜。`lib/core/burn_status.sh:46-48` 早就把這件事
  寫對了，只有這一節停在舊的表達法。

  量（本 commit 的碼，真 helper `lib/core/status_line.sh`、每點 20 連發 ×3 次取中位數、
  沙箱 HOME／CLIKAE_HOME、reefbox、`uptime` load 5.1–7.9）：

  ```
  run dir 數   全 done（最便宜：state 讀完就 continue）   全 running（要驗 pid）
       0                13.3 ms                                   —
      50                21.8 ms                                   —
     100                25.9 ms                              27.7 / 31.7 ms
     200                34.5 ms                                   —
     400                54.0 ms                              67.1 / 68.3 ms
  ```

  **每個 run dir 的邊際成本 ≈ 0.10 ms（全 done）／≈ 0.13 ms（全 running）**，
  固定成本 ≈ 13 ms。所以 30 ms 的預算換算成 run dir 是：在這台機器、這個 load 下
  **約 170 個**（review 在 load 2.9 量到的是 400 個；固定成本與邊際成本都跟 load 走，
  「幾個 run dir 會破預算」不是一個常數，**「每個 run dir 要多少錢」才是**）。
  這台機器現在有 108 個 run dir（`ls -1d ~/.clikae/logs/burn-*`，只數不開檔）。
  ⚠️ 兩張表都是合成的 `status.json`；真實混合（有 `fail`／`waiting-reset`／
  torn 的）沒量。
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

     🔴 **「這一列不准去拿」是對的，但它把「誰去拿」留成了無主的**（2026-09-22）。
     快取檔先前只有兩個寫入者：`clikae usage` 與 burn 在 run 結束時那一次
     （`lib/core/usage.sh` 的 "who writes this cache"）。於是一台**只有人坐在互動
     session、從來不 burn** 的機器，沒有任何東西會去更新它。實測：快取**九天前**寫的，
     狀態列因此永遠畫著「沒有讀數」的 `·`；同一時間另一台整天在 burn 的機器畫的是
     活的數字。手動跑一次 `clikae usage <engine> <tank>` 花 0.7 秒，下一次重畫就是
     `5h 25% · 7d 10%`——**讀數一直是對的，缺的是刷新的責任人**。
     現在的責任人是**這個 session 自己的 `wake` 視窗**（`lib/core/wake.sh`）：
     `wake_watch` 每 `WAKE_USAGE_INTERVAL`（300 秒）呼叫一次 `usage_read`，另外
     `switch.sh` 在**剛 spawn 的** session 上射出一發背景的 `wake_usage_prime`，
     讓第一次 attach 後幾秒鐘就有數字。三件事沒有變：**這一列還是只讀檔**、守望者
     仍然不是 daemon（沒有狀態檔、跟著 session 一起死、不保留任何人的額度模型，見
     `wake.sh` 檔頭的設計約束），以及 300 秒這個地板是 `CLIKAE_USAGE_TTL`（120 秒）
     決定的——比 TTL 更密的節奏只會拿到同一個快取值。
     刷新**不擋迴圈也不出聲**：它的上界是 adapter 自己的 `curl --connect-timeout 3
     --max-time 8`（`lib/adapters/claude.sh`）與 `timeout_bin` 包住的 Keychain 讀取，
     沒有在這裡發明新的上界；失敗就讓上一次的讀數留在檔案裡，由這一列自己的年齡
     後綴去說它多舊（這正是那個後綴存在的理由）。
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
     退出新鮮度判定，燒的是 6 小時後轉綠而不是靠人手動清；燒那一半沒有這個。
     ~~round 1 的修法：死 pid 的 lane 一旦 `updated_at` 超過 `CLIKAE_DRY_TTL` 就不再
     計入 `!N`，「跟 dry 標記變陳舊的判定同一把尺」。~~

     🔴 **P2-3（2026-09-14 round-2 review）：那不是同一把尺。** dry 的時間戳是「觀察到
     乾涸的那一刻」；burn 的 `updated_at` 對 `running`／`waiting-reset` 而言是**這次
     attempt 開始的那一刻**——`lib/commands/burn.sh` 在引擎跑的期間沒有任何週期性改寫，
     它不是心跳。量到：跑了 7 小時才死的 lane → `!0`；等 weekly reset 等了一天才被
     SIGKILL 的 `waiting-reset` → `!0`。**最可能無人看顧地死掉的 lane，正好是這條規則
     永遠報不出來的那種。** 現在的規則：**pid 活著就不紅、死了就紅，不論年齡**；
     `updated_at` 只用來界定「死掉的 lane 最多紅多久」，而那個上限是它自己那份檔案的
     保存期限 `CLIKAE_BURN_LOG_RETENTION_DAYS`（7 天，`_burn_sweep_old_logs` 刪 run dir
     用的同一個旋鈕）——計數永遠不會比證據活得久，從此不再跑 `clikae burn` 的機器也會在
     一週後安靜下來（round 1 的 P2-1 仍然是關的）。代價明說：單一 attempt 開始超過 7 天
     之後才死的 lane 報不出來。沒有加心跳：burn 在引擎執行期間本來就沒有週期性寫入點，
     為這一列發明一個不是小改動。
     **仍然存在的不對稱**：dry 的標記檔本身會被下一次 `dry_store_read`（不是 peek）
     懶惰刪除；burn 的 `status.json` 不會被這條讀路徑刪除——唯一會真的刪除它的仍然是
     `_burn_sweep_old_logs`，7 天、只在 `clikae burn` 才跑，因為 burn 的 `status.json`
     除了 alert-count 之外還有 `clikae wait` 這個真的需要它留著的讀者。兩邊「算不算紅」
     的時鐘也**不是**同一個：dry 是 6 小時的觀察新鮮度，burn 是 pid 存活＋7 天保存期限。

     🔴 **P2-4（同一輪 round-2 review）：dry 那一半原本也有一種永遠不會消失的紅燈。**
     `dry_store_peekv` 把讀不懂的時間戳（非數字、空的、整行沒有 TAB）當成 0，而兩條
     老化分支都要求 `stamp > 0`，於是落到 `fresh`——**永遠**。一次截斷的寫入就會在每個
     session 的狀態列釘一個 `!1`，直到有人手動刪檔。現在讀不懂的時間戳（含
     `dry_store_mark` 在 `date` 失敗時寫的 0）一律是 `expired`：跟 `cached_at` 同一條
     「在，但讀不懂 ⇒ 不可信」的規則。

     🔴 **P2-1（round-4 review）：「讀不讀得懂」這條規則不准把時鐘算進去。** round 3 為了
     擋住「多一位數 ⇒ 年份 2537 ⇒ 永遠 fresh」，加了第三個條件「不得超前 `now` 60 秒」，
     於是**會刪檔的那一臂**變成了讀的人自己的時鐘的函式。讀的人的時鐘可以**落後**寫的人：
     開機時 RTC 快、chrony `makestep` 往回校正、VM snapshot restore、suspend/resume，
     或 `date` 乾脆失敗（兩個讀者的 fallback 都是 `0`）。實測對 `origin/main` 逐格相反：
     落後 61 秒／2 小時／24 小時，以及完全沒有 `date`，都會把一個**幾秒前剛寫下的誠實標記**
     判成 `expired` 並 `rm -f` 掉——burn 立刻回頭撞一個真的在 rate limit 的 tank，
     vendor 原話的 reset phrase 也一起沒了（狀態列 `!4` → `!1`，而且不說為什麼）。
     現在的規則是**純形狀**：全是數字、9 或 10 位。round 3 那個「多一位數」的病仍然被擋著，
     但擋它的是**長度**（11 位是西元 5138 年，沒有任何時鐘寫得出來），不是時鐘。
     隨之而來的三條，寫死在這裡好讓下一次改動得先跟它吵架：
     **（一）這個檔唯一的刪除動作不看時鐘**；**（二）形狀合法但在未來的時間戳＝時鐘動了，
     當成「剛剛記的」（`age` 夾成 0，跟 `tmux_status_fuelv` 對 `cached_at` 同一個決定）、
     照樣算 fresh、**留著**；**（三）`date` 答不出來時的裁決是 `unknown`——保留檔案、
     狀態列照算、burn 照樣視為 dry。刻意接受的代價：一個形狀合法卻真的壞掉的未來時間戳
     現在會被留著而不是被刪掉。判準是不對稱的——判錯 `fresh` 救得回來（下一次成功的 run
     會 `dry_store_clear`，人也刪得掉那一個檔），判錯 `expired` 把證據銷毀，而且把 burn
     送進 rate limit。
  6. **🔴 不准有 emoji。** `scripts/signet-lint.sh` 對任何印出來的 emoji 都會紅
     （只放行 ❯ 游標），而這一列是印出來的。提案原本的 `🔴N` 因此不可能做；它是
     `!N`，顏色由 tmux 上。`○`／`·`／`│` 不在被掃的區段裡，而且 `○`／`·` 本來就是
     board 的字彙（`docs/DESIGN-board-fuel-dots.md`）。

     🔴 **CORRECTION (2026-09-22): the `⏳` (token-expired) mark this rule once
     described here WAS a breach, not an exception, and has been removed.**
     `scripts/signet-lint.sh` only scanned `U+2600–27BF` / `U+1F300–1FAFF` /
     `U+2B00–2BFF` / `U+FE0F` — `⏳` is U+23F3, Miscellaneous Technical, the
     same block as `⌘`/`⌥` (which ARE legitimate key names, so that block
     cannot be banned outright) — so the mark got through the lint gate onto
     a delivery surface it was never allowed on. The fix has two parts: the
     status row's fuel slot now renders the plain word `expired`
     (`tmux_status_fuelv`, `lib/core/tmux.sh`) instead of the glyph — same
     vocabulary the board already uses (`usage_expired_board_notev`,
     `lib/core/usage.sh`), just no longer an emoji — and the lint scan was
     extended to the emoji-presentation code points actually in that block
     (`U+231A–231B`, `U+23E9–23FA`, which covers `⏳`/`⌛`/`⏰`/`⏱`/`⏲`) so the
     same gap cannot reopen with a different glyph from it. `○`/`·` remain
     legitimate: they are outside both the old and the new scanned ranges,
     and they are the board's own established vocabulary
     (`docs/DESIGN-board-fuel-dots.md`), never emoji to begin with.
  7. **寬度規則＝一道固定順序的讓步階梯；警示計數與時鐘永遠不在階梯上。**
     提案指定會截斷的那一段（session 標題）在同一串討論裡被第三次修正拿掉了，之後
     round 1 與 round 2 各自宣告過一次「剩下唯一長度不固定的東西」是什麼，**兩次都漏**：
     round 1 說是別人的主機名，漏掉 round 1 自己加的油量年齡後綴（`· 23h ago`，
     0 或 9–10 欄）；round 2 補上後綴，漏掉 `clikae <engine> <tank>` 這一段本身——
     `validate_name`（`lib/core/profile_store.sh`）限制的是 tank 名的**字元集，不是長度**。
     真 tmux 3.4（外層 `new-session -x N` 當精確 N 欄的模擬器、內層 client attach、
     `capture-pane` 讀最下面那一行）、80 欄、快取 23 小時前，在舊碼 `25a35ff` 上量到：
     24 字元的 claude tank **切掉時鐘**（`!10 1:43`），27 字元的 antigravity tank
     **切掉警示計數本身**（`!10` → `!`，時鐘整個不見）。
     所以規則不再是「哪一段長度不固定」（三段都是），而是「誰先讓」。
     `tmux_status_rowv`——純函式，不讀檔、不叫 `date`、不碰 tmux，所以這個階梯在
     `tests/bats/tmux-status.bats` 裡是一張**表**而不是一段關於終端機的故事——就是那個順序：

     1. `ssh <host> -t ` 前綴：**整段拿掉不是截斷**。半個主機名不是任何人跑得起來的
        指令，而 `clikae resume a52bdc12` 在「你正在讀這一列的那台機器」上本來就完全
        正確。100 欄以下根本不加；100 欄以上也只在**整列加上前綴之後仍然留得下時鐘的
        6 欄**時才加。
     2. 油量的**年齡後綴**（`· 23h ago`）：百分比留著。讀數還是那個讀數，掉的是修飾語。
     3. **tank 名，從中間省略**（`averyverylongtankname` → `aver…name`），地板 8 欄。
        是 elide 不是 truncate，而且一定帶著 `…`：尾巴被砍掉的名字會讀成「另一個真的
        存在的 tank」，**安靜地錯比看得出來短更糟**。
     4. **engine 那個字**（`clikae claude x` → `clikae x`）：這一階之後它就不再是一道
        可以貼上去的指令了，所以它排在四階的最後。
     5. 油量那一段，整段：地板守衛，只有前四階搆不到時才動。它存在的理由是讓下面那
        句話是**不變式**而不是願望。

     🔴 **P3-1（round-4 review）：後面的階讓出來的欄位要還給 tank 名。**
     rung 3 算 tank 名寬度時，列裡還帶著 engine 那個字（7 欄）與整段油量；rung 4／
     rung 5 把它們拿掉之後，騰出來的欄位原本沒有人要——`tshow` 早就釘死了。實測
     （真 tmux 3.4）：claude ＋ 12 字元 tank、40 欄，畫出來是 `clikae tttt…ttt │ !10`，
     33 欄只用了 22 欄，而整個名字只要再 4 欄；24 字元的 tank 被砍到 8 欄，而 20 欄放得下。
     規範承諾的「至少 8 欄」沒有被違反（所以是 P3），但把一個**放得下**的名字省略掉，
     正是 rung 3 自己要防的「讀成另一個 tank」。
     現在 rung 5 之後會用**剩下的欄位**重算一次 tank 名寬度（放得下就整個還原）。
     順序沒有改：還欄位發生在 rung 5 **之後**，所以加寬名字永遠不可能成為油量
     （或任何更低階的東西）被拿掉的理由。

     🔴 **CORRECTION (2026-09-22): this rung's special 2-cell case for `⏳`
     is gone, along with the glyph.** §6's correction above replaced the
     token-expired mark with the plain ASCII word `expired`, which
     `_tmux_status_colsv`'s `${#s}` already measures correctly — no
     substitution needed, the way `AB` never needed one. The width ladder
     never had to change: it always sized the fuel slot as a whole segment
     (rung 5, "never cut the alert count or the clock"), and a 7-column word
     fits that same treatment. What is gone is only the SPECIAL-CASE code
     (`s="${s//⏳/xx}"`) and its 2-cell measurement, both dead now that the
     slot's expired state has no multi-column glyph left to count.

     🔴 **警示計數與時鐘永遠不切。** `!N` 是這一列存在的理由（「什麼是紅的」），而缺了
     小時的時鐘不是時鐘。80 欄**保證**的只有三件事：完整的警示計數、完整的時鐘、以及
     **至少 8 欄的 tank 名**；其餘照上面的順序盡力而為。舊版這裡寫的「其餘最多 59 欄」
     「80 欄永遠不截斷」兩句都作廢——前者在三位數警示（`!100`）時是 60，後者從來沒有對
     長 tank 名成立過。

     🔴 **算術地板不是一個常數，是 `26 + 警示數字的位數`**（P3-2，round-4 review）：
     一位數 27 欄、兩位數 28 欄、三位數 **29** 欄。算法＝`clikae ` 7 ＋ tank 地板 8
     ＋ ` │ !` 4 ＋ 位數 ＋ 時鐘 6 ＋ 行尾 1。舊版寫死的「28 欄」是把 `!10` 當成了全部，
     實測 100 個新鮮 dry 標記、28 欄：helper 算出 23 欄、上限 22，**時鐘被切成 `0:51`**。
     ⚠️ 這是同一個三位數盲點的第三次（round 3 才剛讓「其餘最多 59 欄」退休，
     fix3 就在同一段放進一個帶著同樣盲點的新常數）——所以這裡寫的是**式子不是數字**。
     規範仍然只承諾 80 欄，地板只是「還畫得出完整 `!N` ＋ 完整時鐘」的算術下界。
     階梯表逐階釘住這件事：刪掉任何一階，80 欄那一列就紅。
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
