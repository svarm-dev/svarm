defmodule Svarm.Repo.Migrations.AddAgentQuestionToTaskCoordination do
  use Ecto.Migration

  def change do
    alter table(:task_coordination) do
      add :wait_reason, :string
      add :pending_question, :map
    end
  end
end
