# タスク管理システム（Claude Code 連携）

ローカルファイルシステムをベースに、Claude Code と連携して
タスクの細分化・優先度付け・日報管理を行うシステムです。

---

## セットアップ

### 1. このリポジトリを作業ディレクトリに配置

```bash
# 任意の場所に配置（例: ホームディレクトリ直下）
mv task-system ~/task-system
cd ~/task-system
```

### 2. `task` コマンドをパスに追加

```bash
# ~/.bashrc または ~/.zshrc に追記
echo 'alias task="bash ~/task-system/scripts/task.sh"' >> ~/.zshrc
source ~/.zshrc
```

### 3. 依存ツールの確認

- **jq**: `brew install jq` または `apt install jq`
- **Claude Code**: `npm install -g @anthropic-ai/claude-code`
  - `claude` コマンドでログイン済みであること

---

## 基本的な使い方

### ステップ 1: ゴール（大枠）を登録する

```bash
task add-goal "ダッシュボード機能開発" "管理者向けKPIダッシュボードを実装する"
```

### ステップ 2: Claude Code でタスクに細分化する

```bash
task breakdown g_<goal_id>
```

Claude が自動で:
- 具体的な作業タスクに分解（1タスク = 30〜90分）
- 優先度・見積もり時間を設定
- 依存関係を考慮した順序を提案

### ステップ 3: 今日の計画を立てる

```bash
task plan
```

Claude が優先度・見積もり時間を考慮して、8時間以内の作業計画を自動作成します。

### ステップ 4: 作業を進める

```bash
task start t_<task_id>    # 作業開始
task done t_<task_id> "完了メモ"  # 完了記録
```

### ステップ 5: 状況確認

```bash
task status    # 今日の状況を表示
task list      # タスク一覧
```

### ステップ 6: 日報を生成

```bash
task report
```

---

## コマンド一覧

| コマンド | 説明 |
|---------|------|
| `task add-goal "<タイトル>" "<説明>"` | ゴールを登録 |
| `task goals` | ゴール一覧 |
| `task breakdown <goal_id>` | タスクに細分化（Claude Code） |
| `task plan [date]` | 今日の計画を作成（Claude Code） |
| `task start <task_id>` | 作業開始を記録 |
| `task done <task_id> [メモ]` | 完了を記録 |
| `task status` | 今日の状況を表示 |
| `task list [goal_id]` | タスク一覧 |
| `task report [date]` | 日報を生成（Claude Code） |
| `task edit` | tasks.json を直接編集 |

---

## ファイル構成

```
task-system/
├── CLAUDE.md           # Claude Code への指示書（動作仕様の定義）
├── README.md           # このファイル
├── tasks/
│   └── tasks.json      # タスクデータ（単一ソース）
├── daily/
│   └── YYYY-MM-DD.md  # 日報・作業ログ（日付ごと自動生成）
└── scripts/
    └── task.sh         # CLIコマンド本体
```

---

## Claude Code との連携について

`breakdown`・`plan`・`report` コマンドは内部で `claude --print` を呼び出します。
Claude Code がインストールされ、認証済みであることが必要です。

### Claude Code セッションで直接操作する場合

`CLAUDE.md` をプロジェクトルートに置いているため、
Claude Code を起動すると自動的に指示書が読み込まれます。

```bash
cd ~/task-system
claude
# → Claude が tasks.json を読み込み、文脈を把握した状態で起動
```

### tasks.json のバックアップ

Git で管理することを推奨します:

```bash
cd ~/task-system
git init
echo "daily/" >> .gitignore  # 日報は除外（任意）
git add .
git commit -m "初期設定"
```

---

## カスタマイズ

### 1日の作業時間の変更

`scripts/task.sh` の `cmd_plan` 内のプロンプトで
`8時間（480分）` を変更してください。

### 優先度の判断基準の変更

`CLAUDE.md` の「優先度の判断基準」セクションを編集してください。
Claude Code がその基準に従ってタスクを評価します。
