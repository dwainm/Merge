defmodule Gitastic.Report do
  @moduledoc """
  Plain text for agents: what `gitastic mr wait` prints, and the MCP tools return.
  """

  @doc "The outcome of a wait as the text an agent reads as its next prompt."
  def outcome(%{status: :closed} = o, _url) do
    "Merge request #{o.branch} was closed.\n"
  end

  def outcome(o, url) do
    d = o.decision

    headline =
      case d.verdict do
        :approved -> "APPROVED: #{o.branch} at #{short(d.head)}"
        :needs_work -> "NEEDS WORK: #{o.branch} at #{short(d.head)}"
      end

    [
      headline,
      "\n",
      url && "#{url}\n",
      d.body != "" && "\n#{d.by}: #{d.body}\n",
      comments("Comments", o.comments, []),
      comments("Earlier comments", o.earlier, o.addressed),
      d.verdict == :needs_work &&
        "\nWhen it is fixed: gitastic mr addressed #{o.branch} <commit> --note \"...\", then gitastic mr wait #{o.branch}\n"
    ]
    |> Enum.filter(& &1)
    |> IO.iodata_to_binary()
  end

  defp comments(_title, [], _addressed), do: false

  defp comments(title, comments, addressed) do
    lines =
      comments
      |> Enum.group_by(& &1.round)
      |> Enum.sort()
      |> Enum.flat_map(fn {round, comments} ->
        Enum.map(comments, &comment/1) ++
          for a <- addressed, a.round == round do
            "  -> addressed in #{a.short}#{if a.note, do: ": " <> a.note, else: ""}\n"
          end
      end)

    ["\n#{title}:\n" | lines]
  end

  defp comment(c) do
    where =
      cond do
        c.path && c.line -> "#{c.path}:#{c.line}#{if c.side == "old", do: " (old)", else: ""}"
        c.path -> c.path
        true -> "general"
      end

    at = if c.commit, do: " in #{short(c.commit)}", else: ""
    body = String.replace(c.body, "\n", "\n    ")
    "- [#{where}#{at}] #{c.author}: #{body}\n"
  end

  defp short(nil), do: "?"
  defp short(sha), do: String.slice(sha, 0, 7)
end
