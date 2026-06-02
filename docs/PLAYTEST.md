# clikae 試玩指南 — 10 分鐘上手(v0.5.2)

> 嗨 👋 謝謝你幫忙試 **clikae**。這份帶你從零到「啊我懂了」,大概 10 分鐘。
> 完全不用先懂 clikae。

## clikae 是什麼?

**clikae 是你跟 AI CLI 工作的起點。**

如果你會同時開好幾個 Claude Code / Codex——不同帳號、不同專案、好幾條做到一半的
線,你一定懂那種痛:剛剛那條在哪個終端機?哪個帳號?我到底做到哪了?然後你 `/clear`、
重開、又把專案從頭跟新的 session 講一遍。

clikae 就是來解這個的。打一個 `clikae`,你就會落在**你剛剛在做的所有事**:跨帳號、
跨引擎的最近 session,最新的在最上面,每條還附一句 **recap(做到哪、下一步)**。挑一條、
按 Enter,直接接回你剛剛停下的地方。

- **跨帳號** — 所有帳號一個畫面看完(不只你現在登入的那個)。
- **跨引擎** — Claude Code、Codex、Antigravity、Gemini… 並排。
- **帶 recap** — 免費讀自 Claude 自己的 session 摘要;`●` 還告訴你「接這條要不要換帳號」。

它是一個很小、可完整檢視原始碼、MIT 授權的 bash 工具——沒有常駐程式、沒有遙測、不連網。
(點兩下就開的原生 Mac App 在 roadmap 上;現在先是個好用的 CLI。)

---

## 開始前準備

你需要:

- **macOS 或 Linux**,裝好 **[Homebrew](https://brew.sh)**。
- **至少一個你本來就在用的 AI CLI**——最可能是 **Claude Code**(`claude`),或 **Codex**。
  clikae 不會幫你裝這些,它是來幫你**整理**你已經有的。
- 一個可以登入的 Claude 帳號(Pro / Max)。
- 大約 10 分鐘。

> 已經是 clikae 舊版用戶?直接 `brew upgrade clikae`,然後跳到 **第 3 部分**。

---

## 第 0 部分 — 安裝(1 分鐘)

```bash
brew install CVERInc/clikae/clikae
clikae version          # 應該印出:clikae 0.5.2
```

---

## 第 1 部分 — 建第一個「油箱」(2 分鐘)

一個**油箱(tank)** = 一個帳號/設定檔,各自獨立存放,帳號之間絕不互相污染。
我們先幫 Claude Code 建一個並登入:

```bash
clikae init claude work       # 幫 Claude Code 建一個叫 "work" 的油箱
clikae claude work            # 用這個油箱開 Claude Code
```

第一次開會帶你走 Claude 正常的瀏覽器登入。登入完,**離開 Claude**(`/exit` 或 Ctrl-C)。
你就有一個登入好的油箱了 🎉

> 想多一個帳號來看跨帳號的效果?`clikae init claude personal`,再 `clikae claude personal`,
> 用另一個帳號登入。

---

## 第 2 部分 — 留幾條之後要接回的線(2 分鐘)

板子要「你真的做過事」才會發光。挑一個真實專案,稍微做點東西,留一條可以接回的線:

```bash
cd ~/some-project           # 任何專案資料夾
clikae claude work          # 跟 Claude 工作一下、問它點東西
                            # 然後離開(/exit)
```

這樣做個一兩次(同一個資料夾也行)。session 越真實,recap 越好看。

---

## 第 3 部分 — 板子(重頭戲 🌟)

在一個你用過 Claude 的資料夾裡:

```bash
cd ~/some-project
clikae
```

你應該會看到最上面一個 **「續上次」** 列表,下面是你的油箱。用 `↑/↓`(或 `j/k`)移動,
然後注意:

| 看什麼 | 該看到 |
|---|---|
| **夠快** | 板子大約一秒內出現。 |
| **不閃** | `↑/↓` 移動時畫面乾淨重繪,不會閃。 |
| **續上次列表** | 這個資料夾最近的 session,最新在上,每條有標題。 |
| **游標停會展開 recap** | 選一條 session → 展開一行「做到哪、下一步」。(短/新的 session 會改顯示「多久前」,這是正常的——recap 要夠長的 session 才有。) |
| **● / ○ 點** | ● = 這條在你**現在登入的帳號**上;○ = 接這條要換帳號。 |
| **子訊息跟著跑** | 上下移動時,那行子訊息會換成該 session 的 recap/年齡。 |
| **右下角 logo** | 視窗夠寬夠高時,右下角會有個小 logo(視窗縮小就自動消失)。 |

**按鍵:** `↑/↓` 移動 · `Enter` 開啟 · `r` 接力(relay) · `x` 無痕 · `q` 離開

---

## 第 4 部分 — 接回 & 無痕(2 分鐘)

| 試試看 | 會發生什麼 |
|---|---|
| 選一條**續上次** → 按 `Enter` | 接回*那一條*確切的 Claude session——同一段對話。 |
| 回板子,選一個**油箱** → 按 `x` | 用它開**無痕**:一個乾淨、失憶的 session,離開後什麼都不留。適合一次性的「外科手術」任務。 |
| 選一個**油箱** → 按 `Enter` | 切到那個帳號,開一場全新的 Claude。 |

(任何 session 用 `/exit` 或 Ctrl-C 離開——除了 session 本身,不會多燒任何東西。)

---

## 第 5 部分 —(選用)在地產生的接手筆記

當一條 session 快撞到上限,`clikae to <另一個引擎>` 會把一份**接手筆記**(做了什麼、
下一步)帶到另一個帳號或引擎。clikae 是**在你自己的機器上**寫這份筆記的——如果你有本地
模型(Apple 的在地模型,透過 [`apfel`](https://github.com/Arthur-Ficial/apfel),或
`ollama` / `llm`),你的 session 完全不離開本機、免費、可離線。沒有本地模型?它會退回
一份乾淨的原始摘錄。

```bash
# 選用,macOS:brew install Arthur-Ficial/tap/apfel  (需開啟 Apple Intelligence)
clikae handoff claude        # 印出這個資料夾最新 session 的接手筆記
```

---

## 玩完請回報 🙏

什麼都歡迎!特別想知道:

1. **你有在 10 分鐘內「懂了」嗎?** 哪裡卡住、哪裡看不懂?
2. **板子** — 夠快嗎?乾淨嗎?recap / `●` 點有沒有讓你一眼看懂?
3. **一件**你希望它能做、或覺得怪怪的事。

回個訊息(或一張板子截圖)給團隊就好。**越誠實越好**——這樣才磨得到世界第一讚 🍻

---

_clikae 是 MIT 開源:<https://github.com/CVERInc/clikae> · 完整願景在
[`docs/VISION.md`](./VISION.md)。_
