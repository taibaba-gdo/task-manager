# タスク管理システム — Claude Code 指示書

このプロジェクトはローカルファイルベースのタスク管理システムです。
以下の規則に従って、タスクの細分化・優先度付け・日報連携を担当してください。

---

## ディレクトリ構成

```
task-system/
├── tasks/
│   └── tasks.json          # タスクの永続データ（単一ソース・オブ・トゥルース）
├── daily/
│   └── YYYY-MM-DD.md       # 日報ファイル（日付ごと自動生成）
├── scripts/
│   └── task.sh             # CLIコマンド本体
└── CLAUDE.md               # この指示書
```

---

## データスキーマ

### goals（大枠のゴール）
```json
{
  "id": "g_<timestamp>",
  "title": "ゴールのタイトル",
  "description": "詳細説明",
  "created_at": "2026-01-01T00:00:00+09:00",
  "status": "active | completed | archived"
}
```

### tasks（細分化されたタスク）
```json
{
  "id": "t_<timestamp>",
  "goal_id": "g_xxx",
  "title": "タスクのタイトル",
  "description": "詳細説明",
  "priority": 1,
  "estimated_minutes": 30,
  "status": "todo | in_progress | done | blocked",
  "created_at": "2026-01-01T00:00:00+09:00",
  "started_at": null,
  "done_at": null,
  "notes": ""
}
```

### daily_focus（今日やること）
```json
{
  "date": "2026-01-01",
  "task_ids": ["t_xxx", "t_yyy"]
}
```

---

## Claude Codeが実行するコマンド一覧

以下のコマンドが `task.sh` 経由で呼ばれます。
各コマンドに対し、以下の処理を行ってください。

---

### `breakdown <goal_id>`
**役割**: ゴールをタスクに細分化する

1. `tasks.json` から指定のゴールを読み込む
2. ゴールの内容を分析し、具体的な作業単位（1タスク = 30〜90分以内）に分解する
3. 各タスクに以下を設定する
   - `priority`: 依存関係・重要度・緊急度を考慮した1〜5（1が最高）
   - `estimated_minutes`: 作業時間の見積もり
   - `description`: 具体的な作業内容
4. `tasks.json` の `tasks` 配列に追加する
5. 結果をMarkdown形式で表示する（タスク一覧＋優先度の根拠）

**優先度の判断基準**:
- 他のタスクのブロッカーになるものは最高優先度
- 外部締め切りのあるものは高優先度
- 学習・調査系は低優先度（緊急でなければ）

---

### `plan [date]`
**役割**: 今日（または指定日）にやるタスクを決定する

1. `tasks.json` から `status: todo | in_progress` のタスクを取得
2. 優先度・見積もり時間を考慮して、8時間以内に収まるタスクを選定
3. `daily_focus` を更新する
4. 対応する日報ファイル `daily/YYYY-MM-DD.md` を作成または更新する
5. 今日のプランをMarkdownで表示する

---

### `start <task_id>`
**役割**: タスクの作業開始を記録する

1. 指定タスクの `status` を `in_progress` に変更
2. `started_at` に現在時刻を記録
3. 日報ファイルに「開始」エントリを追加する

---

### `done <task_id> [メモ]`
**役割**: タスク完了を記録する

1. 指定タスクの `status` を `done` に変更
2. `done_at` に現在時刻を記録
3. メモがあれば `notes` に保存
4. 日報ファイルに「完了」エントリと実績時間を追加する

---

### `status`
**役割**: 現在の状況を表示する

以下をまとめて出力する:
1. **今日のフォーカス**: `daily_focus` のタスク一覧と進捗
2. **進行中**: `in_progress` のタスク
3. **優先タスク（Top 5）**: 未完了タスクを優先度順で表示
4. **ゴール進捗**: 各ゴールの完了率（完了タスク数 / 全タスク数）

---

### `report [date]`
**役割**: 日報を生成・表示する

指定日（デフォルト: 今日）の日報ファイルを読み込み、
以下のセクションを含む日報を生成または更新する:

```markdown
# 日報 YYYY年M月D日

## 今日の目標
（daily_focusから）

## 実績
| タスク | ゴール | 開始 | 完了 | 所要時間 |
|--------|--------|------|------|---------|
| ...    | ...    | ...  | ...  | ...min  |

## 明日の予定
（未完了タスクの上位3件）

## メモ
（各タスクのnotesをまとめる）
```

---

### `add_goal <title> <description>`
**役割**: 新しいゴールを登録する

1. IDを生成して `goals` 配列に追加
2. すぐに `breakdown` を実行するか確認する

---

## 重要な規則

- **tasks.json の読み書きは必ずアトミックに行う**（一時ファイル経由で書き込み後にリネーム）
- **日付は日本時間（JST）で処理する**
- **タスクIDは削除しない**（履歴として保持。不要なものは `archived` に変更）
- **優先度の再評価**: `plan` 実行時に、blockedタスクや依存関係を再チェックする
- **見積もりズレの学習**: `done` 時に見積もり vs 実績を記録し、次回の参考にする

---

## コンテキスト継続のコツ

Claude Codeセッション開始時に以下を自動実行すること:
```bash
cat tasks/tasks.json | jq '{
  goals: [.goals[] | select(.status == "active")],
  today_focus: .daily_focus,
  in_progress: [.tasks[] | select(.status == "in_progress")],
  todo_count: [.tasks[] | select(.status == "todo")] | length
}'
```

これでコンテキストを素早く把握できる。
