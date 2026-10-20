defmodule Merge.Events do
  @moduledoc """
  One line per thing that happens, on any merge request or on main:
  `<time> <event> <branch> <detail>`. Each line is appended to
  `~/.merge/events.log` (beside the merge requests, so not in tests or an
  ad-hoc serve) and broadcast on `topic/0` as `{:event, line}`.

  The time is UTC to the microsecond, so a reader that saw a line can ask for
  the ones after it (`since/1`) and get no line twice. No process: whoever
  notices the event calls `emit/3`, so it survives a code reload.
  """

  def topic, do: "events"

  @doc "Records an event. `branch` is the merge request's branch, or \"main\"."
  def emit(event, branch, detail \\ "") do
    time = DateTime.utc_now() |> DateTime.to_iso8601()
    line = Enum.join([time, event, branch, one_line(detail)], " ") |> String.trim_trailing()

    if path = file() do
      File.mkdir_p(Path.dirname(path))
      File.write(path, line <> "\n", [:append])
    end

    Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:event, line})
    :ok
  end

  @doc "The kept lines after `time` (a DateTime; nil for none), oldest first."
  def since(nil), do: []

  def since(%DateTime{} = time) do
    with path when is_binary(path) <- file(),
         {:ok, text} <- File.read(path) do
      text |> String.split("\n", trim: true) |> Enum.filter(&after?(&1, time))
    else
      _ -> []
    end
  end

  @doc "Whether the line's time is after `time`."
  def after?(line, time) do
    case time(line) do
      %DateTime{} = t -> DateTime.compare(t, time) == :gt
      nil -> false
    end
  end

  @doc "The line's time, or nil."
  def time(line) do
    with [stamp | _] <- String.split(line, " ", parts: 2),
         {:ok, t, _} <- DateTime.from_iso8601(stamp) do
      t
    else
      _ -> nil
    end
  end

  @doc "Where the lines are kept: `:events_file`, else beside the store, else nowhere."
  def file do
    case Application.get_env(:merge, :events_file) do
      nil ->
        with dir when is_binary(dir) <- Application.get_env(:merge, :store_dir),
             do: Path.join(Path.dirname(dir), "events.log")

      path ->
        path
    end
  end

  @doc "A short sha."
  def short(nil), do: "?"
  def short(sha), do: String.slice(sha, 0, 7)

  defp one_line(detail) do
    detail |> to_string() |> String.replace(~r/\s*\n\s*/, " ⏎ ") |> String.trim()
  end
end
