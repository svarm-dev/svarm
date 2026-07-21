defmodule Svarm.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    execute("""
    CREATE TABLE IF NOT EXISTS tasks (
      id          TEXT PRIMARY KEY,
      title       TEXT,
      body        TEXT,
      type        TEXT DEFAULT 'code',
      assignee    TEXT,
      status      TEXT DEFAULT 'todo',
      priority    INTEGER DEFAULT 0,
      attempts    INTEGER DEFAULT 0,
      created_by  TEXT DEFAULT 'svarm',
      created_at  INTEGER,
      tenant      TEXT
    );
    """)

    # Indexes: CREATE INDEX IF NOT EXISTS (SQLite 3.9+, safe)
    execute("CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks (status)")
    execute("CREATE INDEX IF NOT EXISTS tasks_tenant_idx ON tasks (tenant)")
    execute("CREATE INDEX IF NOT EXISTS tasks_assignee_idx ON tasks (assignee)")
  end
end
