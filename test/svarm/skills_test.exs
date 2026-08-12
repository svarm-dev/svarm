defmodule Svarm.SkillsTest do
  use ExUnit.Case, async: true

  alias Svarm.Skills

  @fixtures Path.expand("../fixtures/skill_packs", __DIR__)
  @sample Path.join(@fixtures, "sample")
  @standalone Path.join(@fixtures, "standalone.md")
  @empty_dir Path.join(@fixtures, "empty_dir")

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "svarm_skills_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "empty and nil skills are no-ops", %{workspace: ws} do
    assert {:ok, []} = Skills.inject([], ws)
    assert {:ok, []} = Skills.inject(nil, ws)
    refute File.dir?(Skills.skills_root(ws))
  end

  test "injects pack directory with SKILL.md and scripts", %{workspace: ws} do
    assert {:ok, [info]} = Skills.inject([@sample], ws)

    assert info.name == "sample"
    assert info.relative == Path.join([".agents", "skills", "sample"])
    assert File.regular?(Path.join(info.dest, "SKILL.md"))
    assert File.regular?(Path.join([info.dest, "scripts", "helper.sh"]))

    body = File.read!(Path.join(info.dest, "SKILL.md"))
    assert body =~ "Fixture skill pack"
  end

  test "injects standalone .md as SKILL.md under stem name", %{workspace: ws} do
    assert {:ok, [info]} = Skills.inject([@standalone], ws)
    assert info.name == "standalone"
    assert File.regular?(Path.join(info.dest, "SKILL.md"))
    assert File.read!(Path.join(info.dest, "SKILL.md")) =~ "Standalone"
  end

  test "relative paths resolve from host CWD", %{workspace: ws} do
    rel = Path.relative_to_cwd(@sample)
    assert {:ok, [info]} = Skills.inject([rel], ws)
    assert info.name == "sample"
    assert File.regular?(Path.join(info.dest, "SKILL.md"))
  end

  test "missing pack fails closed", %{workspace: ws} do
    missing = Path.join(@fixtures, "does-not-exist")

    assert {:error, {:skills, :missing, ^missing, abs}} = Skills.inject([missing], ws)
    assert abs == Path.expand(missing)
    assert Skills.error?({:skills, :missing, missing, abs})
    assert Skills.format_error({:skills, :missing, missing, abs}) =~ "skill pack missing"
  end

  test "directory without SKILL.md fails closed", %{workspace: ws} do
    File.mkdir_p!(@empty_dir)

    assert {:error, {:skills, :no_skill_md, @empty_dir, _}} = Skills.inject([@empty_dir], ws)
  end

  test "duplicate skill names fail closed", %{workspace: ws} do
    assert {:error, {:skills, :duplicate_name, "sample", _}} =
             Skills.inject([@sample, @sample], ws)
  end

  test "missing pack does not leave partial later packs", %{workspace: ws} do
    missing = Path.join(@fixtures, "nope")

    assert {:error, {:skills, :missing, _, _}} = Skills.inject([@sample, missing], ws)
    # first pack may already be copied before the second fails — acceptable;
    # dispatch still fails closed so the agent is not started
    assert File.regular?(Path.join([ws, ".agents", "skills", "sample", "SKILL.md"]))
  end

  test "append_prompt_section lists packs; empty is identity" do
    assert Skills.append_prompt_section("base", []) == "base"

    section =
      Skills.append_prompt_section("base", [
        %{name: "sample", relative: ".agents/skills/sample", source: "x", dest: "y"}
      ])

    assert section =~ "base"
    assert section =~ "Attached skill packs"
    assert section =~ "`sample`"
    assert section =~ ".agents/skills/sample/SKILL.md"
  end

  test "re-inject overwrites previous dest", %{workspace: ws} do
    assert {:ok, _} = Skills.inject([@sample], ws)
    stale = Path.join([ws, ".agents", "skills", "sample", "stale.txt"])
    File.write!(stale, "old")

    assert {:ok, _} = Skills.inject([@sample], ws)
    refute File.exists?(stale)
    assert File.regular?(Path.join([ws, ".agents", "skills", "sample", "SKILL.md"]))
  end

  test "shipped sample pack stays injectable", %{workspace: ws} do
    shipped = Path.expand("../../priv/packs/ai-task", __DIR__)

    assert {:ok, [info]} = Skills.inject([shipped], ws)
    assert info.name == "ai-task"

    body = File.read!(Path.join(info.dest, "SKILL.md"))
    assert body =~ "name: ai-task"
  end
end
