defmodule Merge.StalePushTest do
  # The last push is kept in the store, which is one for the whole app.
  use ExUnit.Case, async: false

  alias Merge.{Drift, GitRepo, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "merge-store-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :store_dir, Path.join(dir, "merge_requests"))

    on_exit(fn ->
      Application.delete_env(:merge, :store_dir)
      File.rm_rf!(dir)
    end)

    {repo, origin} = GitRepo.with_origin()
    %{repo: repo, origin: origin}
  end

  defp failed_push(tip, to \\ "main"),
    do: %{
      ok: false,
      pushed: false,
      tip: tip,
      to: to,
      output: "Permission denied (publickey).",
      at: DateTime.utc_now()
    }

  test "a failed push stays while its commits are not on GitHub", %{repo: repo} do
    tip = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    Store.put_named("last_push", failed_push(tip))

    Drift.refresh(repo)
    assert %{ok: false, tip: ^tip} = Drift.last_push()
  end

  test "a failed push goes once GitHub's main has its tip, pushed from elsewhere",
       %{repo: repo} do
    # What happened on 4 Nov 2026: Push failed on a refused key; the next push came from
    # a terminal, and the home page went on saying nothing was pushed.
    tip = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    Store.put_named("last_push", failed_push(tip))
    GitRepo.git!(repo, ["push", "-q", "origin", "main"])
    GitRepo.commit!(repo, %{"TWO.md" => "2\n"}, "Two, after")

    Drift.refresh(repo)
    assert Drift.last_push() == nil
  end

  test "without a tip (nothing was ahead), its `to` is what has to be on GitHub",
       %{repo: repo} do
    on_github = GitRepo.git!(repo, ["rev-parse", "origin/main"]) |> String.trim()
    Store.put_named("last_push", failed_push(nil, "bad0000"))
    Drift.refresh(repo)
    assert %{ok: false} = Drift.last_push()

    Store.put_named("last_push", failed_push(nil, on_github))
    Drift.refresh(repo)
    assert Drift.last_push() == nil
  end

  test "a successful push is left alone", %{repo: repo} do
    tip = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    assert %{ok: true} = Drift.push(repo)

    Drift.refresh(repo)
    assert %{ok: true, tip: ^tip} = Drift.last_push()
  end
end
