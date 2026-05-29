#!/usr/bin/env bash
# task.sh — ローカルタスク管理 CLI
# 使い方: task <command> [args...]

set -euo pipefail

# ========== 設定 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$ROOT_DIR/tasks/tasks.json"
DAILY_DIR="$ROOT_DIR/daily"
CLAUDE_MD="$ROOT_DIR/CLAUDE.md"

TODAY=$(date +%Y-%m-%d)
NOW=$(date +"%Y-%m-%dT%H:%M:%S+09:00")

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ========== ユーティリティ ==========

require_jq() {
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}エラー: jq が必要です。brew install jq または apt install jq でインストールしてください。${RESET}"
    exit 1
  fi
}

require_claude() {
  if ! command -v claude &> /dev/null; then
    echo -e "${RED}エラー: claude コマンドが必要です。Claude Code をインストールしてください。${RESET}"
    echo "  https://docs.claude.ai/claude-code"
    exit 1
  fi
}

safe_write() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  echo "$content" > "$tmp"
  mv "$tmp" "$target"
}

get_tasks_json() {
  cat "$TASKS_FILE"
}

gen_id() {
  local prefix="$1"
  echo "${prefix}_$(date +%s%3N)"
}

print_header() {
  echo -e "\n${BOLD}${CYAN}$1${RESET}"
  echo -e "${CYAN}$(printf '%.0s─' {1..50})${RESET}"
}

priority_label() {
  case "$1" in
    1) echo -e "${RED}[P1 最高]${RESET}" ;;
    2) echo -e "${YELLOW}[P2 高  ]${RESET}" ;;
    3) echo -e "${BLUE}[P3 中  ]${RESET}" ;;
    4) echo -e "${RESET}[P4 低  ]${RESET}" ;;
    5) echo -e "${RESET}[P5 最低]${RESET}" ;;
    *) echo "[P?]" ;;
  esac
}

status_icon() {
  case "$1" in
    todo)        echo "○" ;;
    in_progress) echo -e "${GREEN}▶${RESET}" ;;
    done)        echo -e "${GREEN}✓${RESET}" ;;
    blocked)     echo -e "${RED}✗${RESET}" ;;
    *)           echo "?" ;;
  esac
}

# ========== コマンド ==========

cmd_help() {
  cat << 'EOF'

  タスク管理 CLI — コマンド一覧

  ゴール管理
    task add-goal "<タイトル>" "<説明>"   新しいゴールを登録
    task goals                            ゴール一覧を表示

  タスク操作
    task breakdown <goal_id>              ゴールをタスクに細分化（Claude Code 使用）
    task start <task_id>                  タスクの作業開始を記録
    task done <task_id> [メモ]            タスク完了を記録
    task block <task_id> [理由]           タスクをブロック状態にする

  確認・計画
    task status                           今日の状況を表示
    task plan [date]                      今日やるタスクを計画（Claude Code 使用）
    task list [goal_id]                   タスク一覧を表示

  日報
    task report [date]                    日報を生成・表示（Claude Code 使用）

  その他
    task edit                             tasks.json をエディタで開く
    task help                             このヘルプを表示

EOF
}

cmd_add_goal() {
  require_jq
  local title="${1:-}"
  local desc="${2:-}"

  if [[ -z "$title" ]]; then
    echo -e "${RED}エラー: タイトルを指定してください${RESET}"
    echo "  使い方: task add-goal \"<タイトル>\" \"<説明>\""
    exit 1
  fi

  local id
  id=$(gen_id "g")

  local current
  current=$(get_tasks_json)

  local new_goal
  new_goal=$(jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg desc "$desc" \
    --arg now "$NOW" \
    '{id: $id, title: $title, description: $desc, created_at: $now, status: "active"}')

  local updated
  updated=$(echo "$current" | jq --argjson goal "$new_goal" '.goals += [$goal]')
  safe_write "$TASKS_FILE" "$updated"

  echo -e "\n${GREEN}✓ ゴールを登録しました${RESET}"
  echo -e "  ID: ${BOLD}$id${RESET}"
  echo -e "  タイトル: $title"
  echo ""
  echo -e "${YELLOW}次のステップ: タスクに細分化しますか?${RESET}"
  echo -e "  ${CYAN}task breakdown $id${RESET}"
}

cmd_goals() {
  require_jq
  print_header "ゴール一覧"

  local goals
  goals=$(get_tasks_json | jq -r '.goals[] | [.id, .status, .title] | @tsv')

  if [[ -z "$goals" ]]; then
    echo "  登録されたゴールはありません"
    echo -e "  ${CYAN}task add-goal \"<タイトル>\" \"<説明>\"${RESET} で追加できます"
    return
  fi

  while IFS=$'\t' read -r id status title; do
    local icon
    case "$status" in
      active)    icon="${GREEN}●${RESET}" ;;
      completed) icon="${CYAN}✓${RESET}" ;;
      archived)  icon="${RESET}○${RESET}" ;;
      *)         icon="?" ;;
    esac

    # タスク数を取得
    local task_total done_count
    task_total=$(get_tasks_json | jq --arg gid "$id" '[.tasks[] | select(.goal_id == $gid)] | length')
    done_count=$(get_tasks_json | jq --arg gid "$id" '[.tasks[] | select(.goal_id == $gid and .status == "done")] | length')

    echo -e "  $icon ${BOLD}$title${RESET}"
    echo -e "     ID: $id  |  進捗: $done_count/$task_total タスク完了"
  done <<< "$goals"
  echo ""
}

cmd_breakdown() {
  require_jq
  require_claude
  local goal_id="${1:-}"

  if [[ -z "$goal_id" ]]; then
    echo -e "${RED}エラー: goal_id を指定してください${RESET}"
    echo "  使い方: task breakdown <goal_id>"
    cmd_goals
    exit 1
  fi

  # ゴール存在確認
  local goal
  goal=$(get_tasks_json | jq --arg id "$goal_id" '.goals[] | select(.id == $id)' 2>/dev/null)
  if [[ -z "$goal" ]]; then
    echo -e "${RED}エラー: ゴール '$goal_id' が見つかりません${RESET}"
    exit 1
  fi

  local title
  title=$(echo "$goal" | jq -r '.title')
  echo -e "\n${CYAN}Claude Code でタスクを細分化しています...${RESET}"
  echo -e "  ゴール: ${BOLD}$title${RESET}\n"

  # Claude Code に渡すプロンプトを生成
  local prompt
  prompt=$(cat << PROMPT
以下のタスク管理システムの指示に従い、ゴールをタスクに細分化してください。

## 現在のデータ
$(get_tasks_json)

## 対象ゴール
$(echo "$goal")

## 指示
1. このゴールを具体的なタスク（1タスク = 30〜90分）に分解してください
2. 各タスクのpriority（1〜5）とestimated_minutesを設定してください
3. tasks.jsonのtasks配列に追加する形のJSONを出力してください
4. 最後に優先度の判断根拠を日本語で説明してください

## 出力形式
まず以下の形式でJSONを出力（\`\`\`jsonで囲む）:
[
  {
    "id": "t_<unix_timestamp_ms>",
    "goal_id": "$goal_id",
    "title": "タスクタイトル",
    "description": "具体的な作業内容",
    "priority": 1,
    "estimated_minutes": 60,
    "status": "todo",
    "created_at": "$(date +"%Y-%m-%dT%H:%M:%S+09:00")",
    "started_at": null,
    "done_at": null,
    "notes": ""
  }
]

次にMarkdownで優先度の根拠と作業順序を説明してください。
PROMPT
)

  # Claude Code を実行してタスクを生成
  local response
  response=$(echo "$prompt" | claude --print 2>&1) || {
    echo -e "${RED}Claude Code の実行に失敗しました${RESET}"
    echo "$response"
    exit 1
  }

  # JSONブロックを抽出
  local tasks_json
  tasks_json=$(echo "$response" | sed -n '/```json/,/```/p' | grep -v '```' | tr -d '\n' || true)

  if [[ -z "$tasks_json" ]] || ! echo "$tasks_json" | jq . &>/dev/null; then
    echo -e "${YELLOW}JSONの自動パースに失敗しました。Claude の回答を確認してください:${RESET}"
    echo "$response"
    echo ""
    echo -e "${YELLOW}手動で tasks.json を編集するには:${RESET}"
    echo -e "  ${CYAN}task edit${RESET}"
    exit 1
  fi

  # tasks.json に追加
  local current
  current=$(get_tasks_json)
  local updated
  updated=$(echo "$current" | jq --argjson new_tasks "$tasks_json" '.tasks += $new_tasks')
  safe_write "$TASKS_FILE" "$updated"

  local count
  count=$(echo "$tasks_json" | jq 'length')
  echo -e "${GREEN}✓ $count 件のタスクを追加しました${RESET}\n"

  # Claudeの説明部分を表示
  echo "$response" | sed '/```json/,/```/d'

  echo -e "\n${YELLOW}次のステップ:${RESET}"
  echo -e "  ${CYAN}task plan${RESET}  — 今日やるタスクを計画する"
  echo -e "  ${CYAN}task list $goal_id${RESET}  — タスク一覧を確認する"
}

cmd_plan() {
  require_jq
  require_claude
  local date="${1:-$TODAY}"

  echo -e "\n${CYAN}Claude Code で今日の計画を作成しています...${RESET}\n"

  local prompt
  prompt=$(cat << PROMPT
以下のタスク管理データを分析し、${date} の作業計画を立ててください。

## 現在のデータ
$(get_tasks_json)

## 指示
1. status が "todo" または "in_progress" のタスクを取得する
2. 優先度・見積もり時間・ゴールのバランスを考慮して、合計8時間（480分）以内に収まるタスクを選定する
3. 選定したタスクのIDリストをJSONで出力する
4. 今日の作業計画をMarkdown形式で説明する（なぜそのタスクを選んだか）

## 出力形式
まず以下の形式でJSONを出力（\`\`\`jsonで囲む）:
{
  "date": "$date",
  "task_ids": ["t_xxx", "t_yyy"]
}

次にMarkdownで今日の作業計画を説明してください。
PROMPT
)

  local response
  response=$(echo "$prompt" | claude --print 2>&1) || {
    echo -e "${RED}Claude Code の実行に失敗しました${RESET}"
    echo "$response"
    exit 1
  }

  # JSONブロックを抽出
  local plan_json
  plan_json=$(echo "$response" | sed -n '/```json/,/```/p' | grep -v '```' | tr -d '\n' || true)

  if [[ -n "$plan_json" ]] && echo "$plan_json" | jq . &>/dev/null; then
    local current
    current=$(get_tasks_json)
    local updated
    updated=$(echo "$current" | jq --argjson plan "$plan_json" '.daily_focus = $plan')
    safe_write "$TASKS_FILE" "$updated"

    echo -e "${GREEN}✓ 今日の計画を更新しました${RESET}\n"
  fi

  # 日報ファイルを作成
  _ensure_daily_report "$date"

  # Claudeの説明を表示
  echo "$response" | sed '/```json/,/```/d'

  echo -e "\n${YELLOW}タスクを開始するには:${RESET}"
  echo -e "  ${CYAN}task start <task_id>${RESET}"
}

cmd_start() {
  require_jq
  local task_id="${1:-}"

  if [[ -z "$task_id" ]]; then
    echo -e "${RED}エラー: task_id を指定してください${RESET}"
    exit 1
  fi

  local task
  task=$(get_tasks_json | jq --arg id "$task_id" '.tasks[] | select(.id == $id)')
  if [[ -z "$task" ]]; then
    echo -e "${RED}エラー: タスク '$task_id' が見つかりません${RESET}"
    exit 1
  fi

  local title
  title=$(echo "$task" | jq -r '.title')

  local current
  current=$(get_tasks_json)
  local updated
  updated=$(echo "$current" | jq \
    --arg id "$task_id" \
    --arg now "$NOW" \
    '(.tasks[] | select(.id == $id)) |= (.status = "in_progress" | .started_at = $now)')
  safe_write "$TASKS_FILE" "$updated"

  # 日報に記録
  local daily_file="$DAILY_DIR/${TODAY}.md"
  _ensure_daily_report "$TODAY"
  echo "" >> "$daily_file"
  echo "- **${NOW##*T}** 開始: $title \`$task_id\`" >> "$daily_file"

  echo -e "${GREEN}▶ 作業開始: ${BOLD}$title${RESET}"
  echo -e "  開始時刻: ${NOW##*T}"
}

cmd_done() {
  require_jq
  local task_id="${1:-}"
  local memo="${2:-}"

  if [[ -z "$task_id" ]]; then
    echo -e "${RED}エラー: task_id を指定してください${RESET}"
    exit 1
  fi

  local task
  task=$(get_tasks_json | jq --arg id "$task_id" '.tasks[] | select(.id == $id)')
  if [[ -z "$task" ]]; then
    echo -e "${RED}エラー: タスク '$task_id' が見つかりません${RESET}"
    exit 1
  fi

  local title started_at estimated
  title=$(echo "$task" | jq -r '.title')
  started_at=$(echo "$task" | jq -r '.started_at // empty')
  estimated=$(echo "$task" | jq -r '.estimated_minutes')

  # 所要時間を計算
  local elapsed=""
  if [[ -n "$started_at" ]]; then
    local start_epoch end_epoch
    start_epoch=$(date -d "$started_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$started_at" +%s 2>/dev/null || echo 0)
    end_epoch=$(date +%s)
    if [[ "$start_epoch" -gt 0 ]]; then
      elapsed=$(( (end_epoch - start_epoch) / 60 ))
    fi
  fi

  local current
  current=$(get_tasks_json)
  local updated
  updated=$(echo "$current" | jq \
    --arg id "$task_id" \
    --arg now "$NOW" \
    --arg memo "$memo" \
    '(.tasks[] | select(.id == $id)) |= (.status = "done" | .done_at = $now | .notes = $memo)')
  safe_write "$TASKS_FILE" "$updated"

  # 日報に記録
  local daily_file="$DAILY_DIR/${TODAY}.md"
  _ensure_daily_report "$TODAY"
  {
    echo ""
    if [[ -n "$elapsed" ]]; then
      echo "- **${NOW##*T}** 完了: $title \`$task_id\` — 所要時間: ${elapsed}分（見積: ${estimated}分）"
    else
      echo "- **${NOW##*T}** 完了: $title \`$task_id\`"
    fi
    if [[ -n "$memo" ]]; then
      echo "  - メモ: $memo"
    fi
  } >> "$daily_file"

  echo -e "${GREEN}✓ 完了: ${BOLD}$title${RESET}"
  [[ -n "$elapsed" ]] && echo -e "  所要時間: ${elapsed}分（見積: ${estimated}分）"
}

cmd_status() {
  require_jq
  print_header "タスク状況 — $TODAY"

  local data
  data=$(get_tasks_json)

  # 今日のフォーカス
  echo -e "\n${BOLD}今日の計画${RESET}"
  local focus_ids focus_date
  focus_date=$(echo "$data" | jq -r '.daily_focus.date // ""')
  focus_ids=$(echo "$data" | jq -r '.daily_focus.task_ids[]? // empty')

  if [[ -z "$focus_ids" ]] || [[ "$focus_date" != "$TODAY" ]]; then
    echo -e "  ${YELLOW}今日の計画がありません。${RESET} ${CYAN}task plan${RESET} で計画を作成してください。"
  else
    while IFS= read -r tid; do
      local t
      t=$(echo "$data" | jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | "\(.status)\t\(.priority)\t\(.estimated_minutes)\t\(.title)"')
      if [[ -n "$t" ]]; then
        IFS=$'\t' read -r st prio est title <<< "$t"
        local icon
        icon=$(status_icon "$st")
        echo -e "  $icon $(priority_label "$prio") ${title} (${est}分)"
      fi
    done <<< "$focus_ids"
  fi

  # 進行中
  echo -e "\n${BOLD}進行中${RESET}"
  local in_progress
  in_progress=$(echo "$data" | jq -r '.tasks[] | select(.status == "in_progress") | "\(.id)\t\(.title)\t\(.started_at // "-")"')
  if [[ -z "$in_progress" ]]; then
    echo "  進行中のタスクはありません"
  else
    while IFS=$'\t' read -r tid title started; do
      echo -e "  ${GREEN}▶${RESET} ${BOLD}$title${RESET}"
      echo -e "     ID: $tid  |  開始: ${started%%+*}"
    done <<< "$in_progress"
  fi

  # 優先タスク Top 5
  echo -e "\n${BOLD}優先タスク（Top 5）${RESET}"
  local top_tasks
  top_tasks=$(echo "$data" | jq -r '[.tasks[] | select(.status == "todo")] | sort_by(.priority) | .[0:5][] | "\(.priority)\t\(.estimated_minutes)\t\(.title)\t\(.id)"')
  if [[ -z "$top_tasks" ]]; then
    echo "  未着手のタスクはありません"
  else
    while IFS=$'\t' read -r prio est title tid; do
      echo -e "  $(priority_label "$prio") ${title} (${est}分)"
      echo -e "     ${CYAN}$tid${RESET}"
    done <<< "$top_tasks"
  fi

  # ゴール進捗
  echo -e "\n${BOLD}ゴール進捗${RESET}"
  local goals
  goals=$(echo "$data" | jq -r '.goals[] | select(.status == "active") | .id + "\t" + .title')
  if [[ -z "$goals" ]]; then
    echo "  アクティブなゴールはありません"
  else
    while IFS=$'\t' read -r gid gtitle; do
      local total done_c
      total=$(echo "$data" | jq --arg gid "$gid" '[.tasks[] | select(.goal_id == $gid)] | length')
      done_c=$(echo "$data" | jq --arg gid "$gid" '[.tasks[] | select(.goal_id == $gid and .status == "done")] | length')
      local pct=0
      [[ "$total" -gt 0 ]] && pct=$(( done_c * 100 / total ))
      # プログレスバー
      local filled=$(( pct / 5 )) empty=$(( 20 - pct / 5 ))
      local bar
      bar=$(printf '%0.s█' $(seq 1 $filled 2>/dev/null || true))
      bar+=$(printf '%0.s░' $(seq 1 $empty 2>/dev/null || true))
      echo -e "  ${gtitle}"
      echo -e "  ${GREEN}${bar}${RESET} ${pct}% (${done_c}/${total})"
    done <<< "$goals"
  fi
  echo ""
}

cmd_list() {
  require_jq
  local goal_id="${1:-}"

  print_header "タスク一覧${goal_id:+ — $goal_id}"

  local filter='.tasks[]'
  [[ -n "$goal_id" ]] && filter=".tasks[] | select(.goal_id == \"$goal_id\")"

  local tasks
  tasks=$(get_tasks_json | jq -r "$filter | \"\(.status)\t\(.priority)\t\(.estimated_minutes)\t\(.id)\t\(.title)\"")

  if [[ -z "$tasks" ]]; then
    echo "  タスクがありません"
    return
  fi

  while IFS=$'\t' read -r st prio est tid title; do
    local icon
    icon=$(status_icon "$st")
    echo -e "  $icon $(priority_label "$prio") ${title} (${est}分)"
    echo -e "     ${CYAN}$tid${RESET}"
  done <<< "$tasks"
  echo ""
}

cmd_report() {
  require_jq
  require_claude
  local date="${1:-$TODAY}"

  _ensure_daily_report "$date"
  local daily_file="$DAILY_DIR/${date}.md"

  echo -e "\n${CYAN}Claude Code で日報を生成しています...${RESET}\n"

  local prompt
  prompt=$(cat << PROMPT
以下の情報から日報を生成してください。

## タスクデータ
$(get_tasks_json)

## 作業ログ（${date}）
$(cat "$daily_file" 2>/dev/null || echo "（ログなし）")

## 指示
${date} の日報を以下の形式で生成してください:

# 日報 ${date}

## 今日の目標
（daily_focusから取得）

## 実績
| タスク | ゴール | 状態 | 所要時間 |
|--------|--------|------|---------|
（完了・作業中のタスクを記載）

## 振り返り
（見積もり vs 実績のズレ、うまくいった点、課題）

## 明日の予定
（未完了タスクの優先順 Top 3）

## メモ
（各タスクのnotesを集約）

日本語で出力してください。
PROMPT
)

  local response
  response=$(echo "$prompt" | claude --print 2>&1)

  # 日報ファイルに追記
  {
    echo ""
    echo "---"
    echo "## Claude 生成日報"
    echo ""
    echo "$response"
  } >> "$daily_file"

  echo "$response"
  echo -e "\n${GREEN}✓ 日報を保存しました: $daily_file${RESET}"
}

_ensure_daily_report() {
  local date="${1:-$TODAY}"
  local daily_file="$DAILY_DIR/${date}.md"

  if [[ ! -f "$daily_file" ]]; then
    mkdir -p "$DAILY_DIR"
    cat > "$daily_file" << HEADER
# 作業ログ ${date}

## 計画
$(get_tasks_json | jq -r --arg d "$date" '
  if .daily_focus.date == $d then
    .daily_focus.task_ids[] as $id |
    (.tasks[] | select(.id == $id)) |
    "- [ ] \(.title) (\(.estimated_minutes)分)"
  else
    "（計画未設定）"
  end
' 2>/dev/null || echo "（計画未設定）")

## 作業記録
HEADER
  fi
}

cmd_edit() {
  local editor="${EDITOR:-vi}"
  "$editor" "$TASKS_FILE"
}

# ========== エントリポイント ==========

require_jq

# tasks.json が存在しない場合は初期化
if [[ ! -f "$TASKS_FILE" ]]; then
  mkdir -p "$(dirname "$TASKS_FILE")"
  echo '{"goals":[],"tasks":[],"daily_focus":{"date":"","task_ids":[]},"version":"1.0"}' > "$TASKS_FILE"
fi

mkdir -p "$DAILY_DIR"

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  add-goal)   cmd_add_goal "$@" ;;
  goals)      cmd_goals "$@" ;;
  breakdown)  cmd_breakdown "$@" ;;
  plan)       cmd_plan "$@" ;;
  start)      cmd_start "$@" ;;
  done)       cmd_done "$@" ;;
  status)     cmd_status "$@" ;;
  list)       cmd_list "$@" ;;
  report)     cmd_report "$@" ;;
  edit)       cmd_edit "$@" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}不明なコマンド: $COMMAND${RESET}"
    cmd_help
    exit 1
    ;;
esac
