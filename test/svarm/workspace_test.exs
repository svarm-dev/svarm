defmodule Svarm.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Svarm.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "svarm_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  test "path mode creates directory under root", %{root: root} do
    assert {:ok, {path, true}} = Workspace.ensure("ticket-1", root, isolation: :path)
    assert String.starts_with?(path, root)
    assert File.dir?(path)

    assert {:ok, {^path, false}} = Workspace.ensure("ticket-1", root, isolation: :path)

    assert :ok = Workspace.cleanup("ticket-1", root, isolation: :path)
    refute File.dir?(path)
  end

  test "path escape rejected", %{root: root} do
    assert {:error, {:path_escape, _, _}} = Workspace.ensure("..", root)
  end

  test "worktree requires git_repo", %{root: root} do
    assert {:error, :git_repo_required} =
             Workspace.ensure("t1", root, isolation: :worktree)
  end

  test "worktree rejects non-git directory", %{root: root} do
    bare = Path.join(root, "notgit")
    File.mkdir_p!(bare)

    assert {:error, {:not_a_git_repo, _}} =
             Workspace.ensure("t1", root, isolation: :worktree, git_repo: bare)
  end

  test "worktree creates linked working tree", %{root: root} do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["-C", repo, "init", "-b", "main"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README"), "hi\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-m", "init"], stderr_to_stdout: true)

    wt_root = Path.join(root, "trees")
    File.mkdir_p!(wt_root)

    assert {:ok, {path, true}} =
             Workspace.ensure("issue-42", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    assert File.dir?(path)
    assert File.exists?(Path.join(path, "README"))

    assert {:ok, {^path, false}} =
             Workspace.ensure("issue-42", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    assert :ok =
             Workspace.cleanup("issue-42", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    refute File.dir?(path)
    {list, 0} = System.cmd("git", ["-C", repo, "worktree", "list", "--porcelain"])
    refute list =~ path
  end

  test "worktree git timeout returns tagged error", %{root: root} do
    repo = init_git_repo(Path.join(root, "repo"))
    wt_root = Path.join(root, "trees")
    File.mkdir_p!(wt_root)

    hang = Path.join(root, "hang.sh")
    File.write!(hang, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(hang, 0o755)

    assert {:error, :git_timeout} =
             Workspace.ensure("issue-timeout", wt_root,
               isolation: :worktree,
               git_repo: repo,
               git: hang,
               git_timeout_ms: 50
             )

    # Timed-out Port messages must not leak into the next git call.
    assert {:ok, {_path, true}} =
             Workspace.ensure("issue-timeout", wt_root,
               isolation: :worktree,
               git_repo: repo
             )
  end

  test "worktree timeout leftover dir is recovered on next ensure", %{root: root} do
    repo = init_git_repo(Path.join(root, "repo"))
    wt_root = Path.join(root, "trees")
    File.mkdir_p!(wt_root)

    hang = Path.join(root, "hang_mkdir.sh")

    File.write!(hang, """
    #!/bin/sh
    dest=""
    for a in "$@"; do dest="$a"; done
    case "$dest" in
      /*)
        mkdir -p "$dest"
        echo partial > "$dest/partial"
        ;;
    esac
    exec sleep 30
    """)

    File.chmod!(hang, 0o755)

    assert {:error, :git_timeout} =
             Workspace.ensure("issue-leftover", wt_root,
               isolation: :worktree,
               git_repo: repo,
               git: hang,
               git_timeout_ms: 50
             )

    leftover = Path.join(wt_root, "issue-leftover")

    assert {:ok, {^leftover, true}} =
             Workspace.ensure("issue-leftover", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    assert File.exists?(Path.join(leftover, "README"))
    refute File.exists?(Path.join(leftover, "partial"))
  end

  test "worktree recreates leftover path-mode directory", %{root: root} do
    repo = init_git_repo(Path.join(root, "repo"))
    wt_root = Path.join(root, "trees")
    File.mkdir_p!(wt_root)

    leftover = Path.join(wt_root, "issue-99")
    File.mkdir_p!(leftover)
    File.write!(Path.join(leftover, "not-a-checkout"), "x\n")

    assert {:ok, {^leftover, true}} =
             Workspace.ensure("issue-99", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    assert File.exists?(Path.join(leftover, "README"))
    refute File.exists?(Path.join(leftover, "not-a-checkout"))
  end

  test "worktree rejects directory linked to a different repo", %{root: root} do
    repo = init_git_repo(Path.join(root, "repo"))
    other = init_git_repo(Path.join(root, "other"))
    wt_root = Path.join(root, "trees")
    File.mkdir_p!(wt_root)
    dest = Path.join(wt_root, "issue-7")

    {_, 0} =
      System.cmd("git", ["-C", other, "worktree", "add", "-B", "svarm/issue-7", dest],
        stderr_to_stdout: true
      )

    assert {:error, {:not_a_worktree, ^dest}} =
             Workspace.ensure("issue-7", wt_root,
               isolation: :worktree,
               git_repo: repo
             )

    assert File.dir?(dest)
    {list, 0} = System.cmd("git", ["-C", other, "worktree", "list", "--porcelain"])
    assert list =~ dest
  end

  defp init_git_repo(repo) do
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-b", "main"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README"), "hi\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-m", "init"], stderr_to_stdout: true)
    repo
  end
end
