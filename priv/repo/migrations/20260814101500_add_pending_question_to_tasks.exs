defmodule Svarm.Repo.Migrations.AddPendingQuestionToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :wait_reason, :string
      add :pending_question, :map
    end
  end
end
