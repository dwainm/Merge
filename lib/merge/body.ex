defmodule Merge.Body do
  @moduledoc """
  A merge request's body: Markdown, with any `.png` path under `/tmp` it names
  (the streams' screenshots) shown inline as an image served by `/shot`.
  Raw HTML in the body is dropped, not rendered.

  A fenced block tagged `groups` says how the files group on the page (see
  `Merge.Groups`); `split_groups/1` takes it out of the body.
  """

  @groups ~r/```groups[ \t]*\n(.*?)\n?```[ \t]*\n?/s

  @doc "The body without its `groups` block, and the block's text (nil without one)."
  def split_groups(nil), do: {"", nil}

  def split_groups(body) do
    case Regex.run(@groups, body) do
      [whole, text] -> {body |> String.replace(whole, "", global: false) |> String.trim(), text}
      nil -> {body, nil}
    end
  end

  # A Markdown link or image to a /tmp png, or a bare path (in backticks or not).
  @image ~r{!?\[([^\]]*)\]\((/tmp/[^)\s]+\.png)\)|`?(/tmp/[^\s`'"()<>\[\]]+\.png)`?}

  @doc "The `.png` paths under `/tmp` a body names."
  def image_paths(nil), do: []

  def image_paths(body) do
    @image
    |> Regex.scan(body)
    |> Enum.map(fn
      [_, _, link] -> link
      [_, _, "", bare] -> bare
    end)
    |> Enum.uniq()
  end

  @doc "The body as HTML."
  def to_html(body) do
    body
    |> inline_images()
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
      render: [unsafe: false]
    )
  end

  defp inline_images(body) do
    Regex.replace(@image, body, fn
      _, alt, link, "" -> image(link, alt)
      _, _, _, bare -> image(bare, Path.basename(bare))
    end)
  end

  # The image, linked to itself so a tap opens it full size.
  defp image(path, alt) do
    url = MergeWeb.shot_path(path)
    "[![#{alt}](#{url})](#{url})"
  end
end
