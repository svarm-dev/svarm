defmodule Svarm.WorkflowTest do
  use ExUnit.Case, async: true

  alias Svarm.Workflow
  alias Svarm.Workflow.{Config, Render}

  @sample """
  ---
  polling:
    interval_ms: 12000
  tracker:
    active_states: ["todo"]
  ---

  Hello {{issue.title}} / {{attempt}}
  """

  describe "parse/2" do
    test "splits front matter and body" do
      assert {:ok, wf} = Workflow.parse(@sample, "WORKFLOW.md")
      assert wf.config["polling"]["interval_ms"] == 12_000
      assert wf.prompt_template == "Hello {{issue.title}} / {{attempt}}"
    end

    test "rejects missing front matter" do
      assert {:error, :missing_front_matter} = Workflow.parse("no yaml here", "x.md")
    end
  end

  describe "Config.validate_workflow/1" do
    test "accepts priv-style template" do
      path = Path.join(:code.priv_dir(:svarm), "workflow_template.md")
      assert {:ok, wf} = Workflow.load(path)
      assert :ok = Config.validate_workflow(wf)
    end

    test "rejects empty prompt" do
      wf = %Workflow{config: %{}, prompt_template: "", path: "x"}
      assert {:error, :empty_prompt_template} = Config.validate_workflow(wf)
    end

    test "rejects pending_approval in active_states" do
      wf = %Workflow{
        config: %{"tracker" => %{"active_states" => ["todo", "pending_approval"]}},
        prompt_template: "ok",
        path: "x"
      }

      assert {:error, :pending_approval_in_active_states} = Config.validate_workflow(wf)
    end
  end

  describe "Render.render/3" do
    test "substitutes issue fields and attempt" do
      task = %{id: "sva_1", title: "Fix bug", body: "details", status: "todo", assignee: "cody"}

      assert {:ok, rendered} =
               Render.render(
                 "{{issue.id}}:{{issue.title}}:{{issue.description}}:{{attempt}}",
                 task,
                 2
               )

      assert rendered == "sva_1:Fix bug:details:2"
    end

    test "returns error for unknown placeholder" do
      task = %{id: "sva_1", title: "x"}

      assert {:error, {:unknown_placeholders, ["issue.foo"]}} =
               Render.render("{{issue.id}} {{issue.foo}}", task)
    end

    test "validate/1 detects unknown" do
      assert {:error, {:unknown_placeholders, ["foo"]}} = Render.validate("hello {{foo}}")
      assert :ok = Render.validate("ok {{issue.title}} {{attempt}}")
    end
  end

  describe "Config.from_map/1 workspace isolation" do
    test "defaults to path when omitted" do
      assert Config.from_map(%{}).workspace_isolation == :path
      assert Config.from_map(%{"workspace" => %{}}).workspace_isolation == :path
    end

    test "parses path" do
      cfg = Config.from_map(%{"workspace" => %{"isolation" => "path"}})
      assert cfg.workspace_isolation == :path
    end

    test "parses worktree" do
      cfg = Config.from_map(%{"workspace" => %{"isolation" => "worktree"}})
      assert cfg.workspace_isolation == :worktree
    end

    test "does not coerce invalid values to path" do
      for value <- ["container", "sandbox", "Worktree", "worktrees", ""] do
        cfg = Config.from_map(%{"workspace" => %{"isolation" => value}})

        assert cfg.workspace_isolation == {:error, :invalid_workspace_isolation},
               "expected error for #{inspect(value)}, got #{inspect(cfg.workspace_isolation)}"
      end
    end
  end

  describe "Config.validate_workflow/1 workspace isolation" do
    test "accepts omitted isolation (default path)" do
      wf = %Workflow{config: %{}, prompt_template: "Do {{issue.id}}", path: "x"}
      assert :ok = Config.validate_workflow(wf)
    end

    test "accepts path" do
      wf = %Workflow{
        config: %{"workspace" => %{"isolation" => "path"}},
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert :ok = Config.validate_workflow(wf)
    end

    test "accepts worktree" do
      wf = %Workflow{
        config: %{"workspace" => %{"isolation" => "worktree"}},
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert :ok = Config.validate_workflow(wf)
    end

    test "rejects unknown isolation with a tagged error" do
      for value <- ["container", "sandbox", "garbage"] do
        wf = %Workflow{
          config: %{"workspace" => %{"isolation" => value}},
          prompt_template: "Do {{issue.id}}",
          path: "x"
        }

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, :invalid_workspace_isolation} = Config.validate_workflow(wf)
          end)

        assert log =~ inspect(value)
      end
    end
  end

  describe "Config.review_checklist/1" do
    test "omitted, empty, or non-list are empty" do
      assert Config.review_checklist(%{}) == []
      assert Config.review_checklist(%{"review" => %{}}) == []
      assert Config.review_checklist(%{"review" => %{"checklist" => "pr"}}) == []
      assert Config.review_checklist(nil) == []
    end

    test "string ids get friendly default labels for known ids" do
      items = Config.review_checklist(%{"review" => %{"checklist" => ["pr", "ci", "cost"]}})

      assert items == [
               %{id: "pr", label: "PR"},
               %{id: "ci", label: "CI"},
               %{id: "cost", label: "Cost"}
             ]
    end

    test "{id, label} maps keep given labels" do
      items =
        Config.review_checklist(%{
          "review" => %{"checklist" => [%{"id" => "pr", "label" => "Pull request"}]}
        })

      assert items == [%{id: "pr", label: "Pull request"}]
    end

    test "custom ids keep the given label (or the id itself)" do
      items =
        Config.review_checklist(%{
          "review" => %{
            "checklist" => [
              "documentation",
              %{"id" => "docs", "label" => "Docs link"},
              %{id: "deploy", label: "Deploy"}
            ]
          }
        })

      assert items == [
               %{id: "documentation", label: "documentation"},
               %{id: "docs", label: "Docs link"},
               %{id: "deploy", label: "Deploy"}
             ]
    end

    test "malformed entries are skipped and never fail validation" do
      config = %{
        "review" => %{
          "checklist" => [
            "pr",
            123,
            nil,
            %{},
            %{"id" => ""},
            %{"id" => 42},
            %{"label" => "no id"},
            # valid ids with blank / non-string labels fall back to defaults
            %{"id" => "ci", "label" => "  "},
            %{"id" => "cost", "label" => 99}
          ]
        }
      }

      assert Config.review_checklist(config) == [
               %{id: "pr", label: "PR"},
               %{id: "ci", label: "CI"},
               %{id: "cost", label: "Cost"}
             ]

      wf = %Workflow{config: config, prompt_template: "Do {{issue.id}}", path: "x"}
      assert :ok = Config.validate_workflow(wf)
    end

    test "from_map exposes review_checklist alongside typed getters" do
      cfg = Config.from_map(%{})
      assert cfg.review_checklist == []

      cfg = Config.from_map(%{"review" => %{"checklist" => ["pr", "cost"]}})
      assert Enum.map(cfg.review_checklist, & &1.id) == ["pr", "cost"]
    end
  end

  describe "Config.validate_workflow/1 (strict render)" do
    test "rejects unknown placeholders in prompt_template" do
      wf = %Workflow{
        config: %{},
        prompt_template: "Do {{issue.id}} then {{weird.var}}",
        path: "x"
      }

      assert {:error, :invalid_prompt_template} = Config.validate_workflow(wf)
    end
  end

  describe "Config.tracker_config status_labels / reverse_labels" do
    test "parses custom maps from WORKFLOW YAML" do
      yaml = """
      ---
      tracker:
        kind: github
        owner: acme
        repo: demo
        status_labels:
          "gate: wait": pending_approval
        reverse_labels:
          pending_approval: "gate: wait"
        extra_future_key: true
      ---

      Do {{issue.id}}
      """

      assert {:ok, wf} = Workflow.parse(yaml)
      assert :ok = Config.validate_workflow(wf)
      cfg = Config.tracker_config(wf.config)
      assert cfg.status_labels["gate: wait"] == "pending_approval"
      assert cfg.reverse_labels["pending_approval"] == "gate: wait"
    end

    test "omitted maps are not on tracker_config (adapter defaults apply)" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{"kind" => "github", "owner" => "acme", "repo" => "demo"}
        })

      refute Map.has_key?(cfg, :status_labels)
      refute Map.has_key?(cfg, :reverse_labels)
    end

    test "unknown extra tracker keys and extra label-map keys do not crash" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "not_a_real_key" => 123,
            "status_labels" => %{
              "status: pending-approval" => "pending_approval",
              "custom: extra" => "other"
            }
          }
        })

      assert cfg.kind == :github
      assert cfg.owner == "acme"
      assert cfg.status_labels["custom: extra"] == "other"
      assert cfg.status_labels["status: pending-approval"] == "pending_approval"
    end

    test "non-map status_labels fail closed" do
      wf = %Workflow{
        config: %{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "status_labels" => ["not", "a", "map"]
          }
        },
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert {:error, :invalid_tracker_status_labels} = Config.validate_workflow(wf)
    end

    test "non-string status_labels entries fail closed" do
      wf = %Workflow{
        config: %{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "status_labels" => %{"status: pending-approval" => 1}
          }
        },
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert {:error, :invalid_tracker_status_labels} = Config.validate_workflow(wf)
    end

    test "non-map reverse_labels fail closed" do
      wf = %Workflow{
        config: %{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "reverse_labels" => "nope"
          }
        },
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert {:error, :invalid_tracker_reverse_labels} = Config.validate_workflow(wf)
    end

    test "blank label-map values fail closed" do
      wf = %Workflow{
        config: %{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "reverse_labels" => %{"pending_approval" => "  "}
          }
        },
        prompt_template: "Do {{issue.id}}",
        path: "x"
      }

      assert {:error, :invalid_tracker_reverse_labels} = Config.validate_workflow(wf)
    end
  end

  describe "Config.tracker_config GitHub App auth" do
    test "parses auth: app and literal app_id" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "auth" => "app",
            "app_id" => "12345",
            "private_key_path" => "/tmp/app.pem"
          }
        })

      assert cfg.auth == :app
      assert cfg.owner == "acme"
      assert cfg.app_id == "12345"
      assert cfg.private_key_path == "/tmp/app.pem"
    end

    test "defaults to token auth" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{"kind" => "github", "owner" => "a", "repo" => "b"}
        })

      assert cfg.auth == :token
    end

    test "parses agent_assignees and defaults to empty" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "demo",
            "agent_assignees" => ["svarm-bot[bot]", "demo"]
          }
        })

      assert cfg.agent_assignees == ["svarm-bot[bot]", "demo"]

      omitted =
        Config.tracker_config(%{
          "tracker" => %{"kind" => "github", "owner" => "a", "repo" => "b"}
        })

      assert omitted.agent_assignees == []
    end

    test "validate rejects incomplete app auth" do
      # Host .env may set SVARM_GITHUB_*; clear for this assertion.
      keys =
        ~w(SVARM_GITHUB_APP_ID SVARM_GITHUB_APP_KEY_PATH SVARM_GITHUB_APP_PRIVATE_KEY SVARM_GITHUB_INSTALLATION_ID)

      saved = Enum.map(keys, &{&1, System.get_env(&1)})
      Enum.each(keys, &System.delete_env/1)

      try do
        wf = %Workflow{
          config: %{
            "tracker" => %{
              "kind" => "github",
              "owner" => "a",
              "repo" => "b",
              "auth" => "app"
            }
          },
          prompt_template: "Do {{issue.id}}",
          path: "x"
        }

        assert {:error, :github_app_auth_incomplete} = Config.validate_workflow(wf)
      after
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end
  end
end
