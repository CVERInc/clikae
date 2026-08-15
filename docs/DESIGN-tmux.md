# DESIGN-tmux: Clikae Tmux Orchestration

**Status**: Active
**Scope**: This document owns the lifecycle, environment isolation, and terminal rendering (Tmux) rules for Clikae tanks.
**Boundary**: This is the Single Source of Truth for Tmux interactions. Where `orchestration.md` or `DESIGN-runtime.md` disagrees with this file regarding Tmux, this file wins.

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
  tmux set-option -g history-limit 50000 \; new-session -d -e "CLIKAE_TANK_NAME=$tank" -s "ck-<run_id>" "..."
  ```
  🔴 **這條被違反過，而且是靜音的。** `burn.sh` 用的是裸的 `tmux new-session -d`，一個前綴都沒有。因為 `switch` 之後會補上全域選項，所以只有「burn 是第一個跑的東西」那一瞬間看得到；量到的（2026-08-15，隔離 socket）：
  ```
  $ # 沒有既存 server，用 burn 生一顆，趁它還活著問
  $ tmux show-options -gv history-limit
  2000          # tmux 的預設，不是我們的 50000
  ```
  收斂到 `tmux_spawn_session` 之後回到 50000。`tests/bats/tmux-spawn.bats` 釘住它——那個測試在修之前是紅的。
  ⚠️ **量的時候 server 必須還活著**：`exit-empty` 讓 server 隨最後一個 session 消失，而對死掉的 server 問選項會**默默起一顆新的**、回答 tmux 的預設值——長得跟 bug 一模一樣，不管 bug 在不在。
  互動模式時使用 `tmux attach -t "ck-<tank>"`，不再強制使用 `-D` 踢除舊連線（允許在多個視窗中同時查看同一個 session，將控制權交由使用者自行協調）。`window-size latest` 下最近使用的 client 決定尺寸，兩個 client 並存不會坍塌，離開會自動彈回。這是「不需要 -D」的真正理由。


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
    tmux has-session -t "ck-<tank>" 2>/dev/null || tmux_spawn_session --session "ck-<tank>" …
    CLIENTS=$(tmux list-clients -t "$CURRENT_PANE_SESSION" 2>/dev/null)
    if [ -n "$CLIENTS" ]; then
      tmux switch-client -t "ck-<tank>"
    fi
  else
    clikae_spawn_session "<tank>"
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
- **規範**：
  無痕模式必須利用 shell redirect 與 FD，保持鎖的生命週期綁定在 client attach 期間（正常 detach 也會觸發 GC 刪除）：
  ```bash
  exec 9> "${TMPDIR:-/tmp}/ck-ephem-<run_id>.lock"
  lockf -k -t 0 9
  exec tmux attach -t "ck-<run_id>"
  # 警告：exec 9> 與 exec tmux 之間，嚴禁任何 subshell 或關閉 FD 的操作
  ```
  清理巡邏程式 `clikae clean` 檢查鎖時，必須精確判斷 `rc==75`，且絕對禁止刪除鎖檔（交由 OS 定期清理 TMPDIR）：
  ```bash
  lockf -k -t 0 "${TMPDIR:-/tmp}/ck-ephem-<run_id>.lock" true 2>/dev/null
  rc=$?
  if [ $rc -eq 0 ]; then
    # 搶鎖成功代表 FD 已釋放 (client 已斷開)
    tmux kill-session -t "ck-<run_id>" 2>/dev/null
  elif [ $rc -ne 75 ]; then
    echo "ERROR: lockf failed with rc=$rc" >&2
  fi
  ```
  FIRES: 模擬搶鎖失敗
  ```
  $ bash -c 'exec 9> /tmp/ck-ephem-test.lock; lockf -k -t 0 9; lockf -k -t 0 /tmp/ck-ephem-test.lock true 2>/dev/null; echo $?'
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

  🔴 **這個不對稱本身可能是個 bug，而且方向跟直覺相反：問題在 `switch` 那一邊。** 精選清單以外的每一個變數，session 拿到的是 **server 的**環境——也就是「當初誰起的 server」的環境，不是使用者此刻的。`tests/bats/roam.bats` 的間歇性失敗就是這個（`STUB_RUNS` 只有在該測試自己起 server 時才傳得到）。
  把 `switch` 也改成走 wrapper 檔傳整份環境，理論上會讓漫遊 session 免疫於這件事，但那是**行為變更**、風險不對稱（會改變既有 session 看到的環境），所以另案處理，不塞在這次重構裡。
