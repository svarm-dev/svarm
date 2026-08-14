defmodule Svarm.Repo.Migrations.AddReviewDecisionToTaskCoordination do
  use Ecto.Migration

  def change do
    alter table(:task_coordination) do
      add :review_decision, :string
      add :review_last_head_sha, :string
      add :review_context_summary, :text
    end
  end
end
