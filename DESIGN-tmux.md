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
  互動模式時使用 `tmux attach -t "ck-<tank>"`，不再強制使用 `-D` 踢除舊連線（允許在多個視窗中同時查看同一個 session，將控制權交由使用者自行協調）。`window-size latest` 下最近使用的 client 決定尺寸，兩個 client 並存不會坍塌，離開會自動彈回。這是「不需要 -D」的真正理由。

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
    tmux has-session -t "ck-<tank>" 2>/dev/null || clikae_spawn_session "<tank>"
    CLIENTS=$(tmux list-clients -t "$CURRENT_PANE_SESSION" 2>/dev/null)
    if [ -n "$CLIENTS" ]; then
      tmux switch-client -t "ck-<tank>"
    fi
  else
    clikae_spawn_session "<tank>"
  fi
  ```
  *(備註：`clikae_spawn_session` 是上述 Rule 1 與 Rule 2 的封裝函式)*
  
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
