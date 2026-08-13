defmodule Svarm.Tracker.GitHub.ReviewsTest do
  use ExUnit.Case, async: true

  alias Svarm.Tracker.GitHub.Reviews

  describe "classify/3" do
    test "changes_requested from latest submitted review" do
      reviews = [
        %{
          "user" => %{"login" => "alice"},
          "state" => "CHANGES_REQUESTED",
          "submitted_at" => "2026-08-01T10:00:00Z"
        }
      ]

      assert %{
               decision: :changes_requested,
               reviewer_logins: ["alice"],
               head_sha: "abc"
             } = Reviews.classify(reviews, "abc")
    end

    test "later approval supersedes earlier changes requested from same user" do
      reviews = [
        %{
          "user" => %{"login" => "alice"},
          "state" => "CHANGES_REQUESTED",
          "submitted_at" => "2026-08-01T10:00:00Z"
        },
        %{
          "user" => %{"login" => "alice"},
          "state" => "APPROVED",
          "submitted_at" => "2026-08-01T12:00:00Z"
        }
      ]

      assert %{decision: :none, reviewer_logins: []} = Reviews.classify(reviews, "s")
    end

    test "another reviewer's later approval does not hide changes requested" do
      reviews = [
        %{
          "user" => %{"login" => "alice"},
          "state" => "CHANGES_REQUESTED",
          "submitted_at" => "2026-08-01T10:00:00Z"
        },
        %{
          "user" => %{"login" => "bob"},
          "state" => "APPROVED",
          "submitted_at" => "2026-08-01T12:00:00Z"
        }
      ]

      assert %{decision: :changes_requested, reviewer_logins: ["alice"]} =
               Reviews.classify(reviews, "s")
    end

    test "ignores PENDING and DISMISSED" do
      reviews = [
        %{"user" => %{"login" => "alice"}, "state" => "PENDING", "submitted_at" => nil},
        %{
          "user" => %{"login" => "bob"},
          "state" => "DISMISSED",
          "submitted_at" => "2026-08-01T10:00:00Z"
        }
      ]

      assert %{decision: :none, review_count: 2} = Reviews.classify(reviews, "s")
    end

    test "empty reviews is none" do
      assert %{decision: :none, review_count: 0} = Reviews.classify([], "s")
    end
  end

  describe "summarize_pr_reviews/5 with stub Req" do
    defmodule StubReq do
      def get(url, opts) do
        cond do
          String.contains?(url, "/reviews") ->
            reviews = Process.get(:stub_reviews, [])
            {:ok, %{status: 200, body: reviews}}

          String.contains?(url, "/pulls/") ->
            case Process.get(:stub_pr, :ok) do
              :missing_sha ->
                {:ok, %{status: 200, body: %{"head" => %{}, "draft" => false}}}

              _ ->
                {:ok, %{status: 200, body: %{"head" => %{"sha" => "deadbeef"}, "draft" => false}}}
            end

          true ->
            flunk("unexpected URL #{url} opts=#{inspect(opts)}")
        end
      end
    end

    test "changes requested from fixture reviews" do
      Process.put(:stub_pr, :ok)

      Process.put(:stub_reviews, [
        %{
          "user" => %{"login" => "rev"},
          "state" => "CHANGES_REQUESTED",
          "submitted_at" => "2026-08-13T00:00:00Z"
        }
      ])

      assert {:ok,
              %{
                decision: :changes_requested,
                head_sha: "deadbeef",
                reviewer_logins: ["rev"]
              }} =
               Reviews.summarize_pr_reviews("o", "r", 7, %{api_key: "t"}, req: StubReq)
    end

    test "missing head sha errors" do
      Process.put(:stub_pr, :missing_sha)

      assert {:error, :missing_head_sha} =
               Reviews.summarize_pr_reviews("o", "r", 1, %{api_key: "t"}, req: StubReq)
    end
  end
end
