-- Orchestrator SQLite schema
-- Replaces tasks.yml and jobs.yml for better performance, concurrency, and querying.
-- Configure SQLite for concurrent access
-- Note: journal_mode returns 'wal', this is normal
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;


CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT DEFAULT '',
  status TEXT NOT NULL DEFAULT 'new',
  agent TEXT,
  agent_model TEXT,
  agent_profile TEXT,       -- JSON string
  complexity TEXT,
  parent_id INTEGER REFERENCES tasks(id),
  route_reason TEXT,
  route_warning TEXT,
  summary TEXT,
  reason TEXT,
  needs_help INTEGER DEFAULT 0,
  attempts INTEGER DEFAULT 0,
  last_error TEXT,
  prompt_hash TEXT,
  last_comment_hash TEXT,
  retry_at TEXT,
  review_decision TEXT,
  review_notes TEXT,
  dir TEXT,
  branch TEXT,
  worktree TEXT,
  worktree_cleaned INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  -- GitHub sync fields
  gh_issue_number INTEGER,
  gh_state TEXT,
  gh_url TEXT,
  gh_updated_at TEXT,
  gh_synced_at TEXT,
  gh_last_feedback_at TEXT,
  gh_project_item_id TEXT,
  gh_archived INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS task_labels (
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY (task_id, label)
);

CREATE TABLE IF NOT EXISTS task_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  ts TEXT NOT NULL,
  status TEXT,
  note TEXT
);

CREATE TABLE IF NOT EXISTS task_files (
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  file_path TEXT NOT NULL,
  PRIMARY KEY (task_id, file_path)
);

CREATE TABLE IF NOT EXISTS task_children (
  parent_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  child_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (parent_id, child_id)
);

CREATE TABLE IF NOT EXISTS task_accomplished (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  item TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_remaining (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  item TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_blockers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  item TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_selected_skills (
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  skill TEXT NOT NULL,
  PRIMARY KEY (task_id, skill)
);

CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  schedule TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'task',
  command TEXT,
  body TEXT DEFAULT '',
  labels TEXT DEFAULT '',
  agent TEXT,
  dir TEXT,
  enabled INTEGER DEFAULT 1,
  active_task_id INTEGER,
  last_run TEXT,
  last_task_status TEXT,
  created_at TEXT NOT NULL
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_dir ON tasks(dir);
CREATE INDEX IF NOT EXISTS idx_tasks_gh_issue ON tasks(gh_issue_number);
CREATE INDEX IF NOT EXISTS idx_tasks_updated ON tasks(updated_at);
CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status_dir ON tasks(status, dir);
CREATE INDEX IF NOT EXISTS idx_history_task ON task_history(task_id);
CREATE INDEX IF NOT EXISTS idx_labels_task ON task_labels(task_id);
CREATE INDEX IF NOT EXISTS idx_labels_label ON task_labels(label);
CREATE INDEX IF NOT EXISTS idx_children_parent ON task_children(parent_id);
CREATE INDEX IF NOT EXISTS idx_children_child ON task_children(child_id);
