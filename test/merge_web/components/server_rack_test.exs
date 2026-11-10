defmodule MergeWeb.ServerRackTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MergeWeb.MergeRequestComponents

  defp tree(status, reason \\ nil) do
    %{
      path: "/trees/app",
      name: "app",
      branch: "main",
      url: if(status == :off, do: nil, else: "https://app.dev.example.com/"),
      status: status,
      reason: reason,
      dev?: true
    }
  end

  # The rack's button, and what is drawn in it.
  defp rack(tree, run \\ nil) do
    html = render_component(&MergeRequestComponents.server/1, tree: tree, run: run)
    button = html |> LazyHTML.from_fragment() |> LazyHTML.query("button#rack-trees-app")
    svg = LazyHTML.query(button, "svg.rack")
    assert LazyHTML.attribute(button, "phx-click") == ["server_open"]

    %{
      state: svg |> LazyHTML.attribute("data-state") |> List.first(),
      title: button |> LazyHTML.attribute("title") |> List.first(),
      class: svg |> LazyHTML.attribute("class") |> List.first(),
      lights: svg |> LazyHTML.query("circle[fill]") |> Enum.count(),
      rings: svg |> LazyHTML.query("circle[stroke]") |> Enum.count(),
      marks: svg |> LazyHTML.query("path") |> Enum.count(),
      dashed: svg |> LazyHTML.query("g[stroke-dasharray]") |> Enum.count()
    }
  end

  test "up: blue, both lights lit" do
    r = rack(tree(:up))
    assert %{state: "up", title: "Up", lights: 2, rings: 0, dashed: 0} = r
    assert r.class =~ "text-(--info-text)"
  end

  test "answering with an error: amber, one light and a cross, the reason on hover" do
    r = rack(tree(:error, "CompileError at GET /"))
    assert %{state: "error", title: "Error: CompileError at GET /", lights: 1, marks: 2} = r
    assert r.class =~ "text-(--warn-text)"
  end

  test "not answering: purple, both lights out" do
    r = rack(tree(:not_answering, "not answering"))
    assert %{state: "not_answering", title: "Not answering", lights: 0, rings: 2} = r
    assert r.class =~ "text-(--merged-text)"
  end

  test "nothing listening: grey, dashed, no lights" do
    r = rack(tree(:off))
    assert %{state: "off", title: "No server", lights: 0, rings: 0, dashed: 1, marks: 0} = r
    assert r.class =~ "text-(--text-faint)"
  end

  test "an action running: pink, blinking, the action on hover" do
    r = rack(tree(:up), %{state: :running, action: :restart, name: "app"})
    assert %{state: "running", title: "Restarting… (Up)", lights: 2} = r
    assert r.class =~ "rack-running"
    assert r.class =~ "text-(--pending-text)"
  end

  test "no state wears the checks' green or red" do
    running = %{state: :running, action: :off, name: "app"}

    for {status, run} <- [up: nil, error: nil, not_answering: nil, off: nil, up: running] do
      class = rack(tree(status), run).class
      refute class =~ "--ok-"
      refute class =~ "--bad-"
    end
  end
end
