defmodule MergeWeb.ServerSheetHook do
  @moduledoc """
  Gives a LiveView the server sheet: tapping a tree's dot opens it
  (`@server_sheet`, the tree, with `@server_log`, the last lines of its log),
  and its Restart, Reseed and Turn off run the tree's `bin/dev`
  (`Merge.DevScript`). `@dev_runs` is every tree's last run, for the dots.
  Render `MergeWeb.MergeRequestComponents.server_sheet/1` with these.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Merge.{DevScript, Servers}

  @log_dir "/tmp/dop-servers"
  @log_lines 20

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Merge.PubSub, Servers.topic())

    socket =
      socket
      |> assign(:server_sheet, nil)
      |> assign(:server_log, nil)
      |> assign(:server_error, nil)
      |> assign(:dev_runs, if(Process.whereis(DevScript), do: DevScript.runs(), else: %{}))
      |> attach_hook(:server_sheet_info, :handle_info, &info/2)
      |> attach_hook(:server_sheet_event, :handle_event, &event/3)

    {:cont, socket}
  end

  defp info({:dev_runs, runs}, socket),
    do: {:halt, socket |> assign(:dev_runs, runs) |> reload()}

  # The page wants this too, for its own dots.
  defp info({:servers, repos}, socket), do: {:cont, reload(socket, repos)}
  defp info(_msg, socket), do: {:cont, socket}

  defp event("server_open", %{"path" => path}, socket) do
    tree = find(Servers.current() || Servers.read(), path)

    {:halt,
     socket
     |> assign(:server_sheet, tree)
     |> assign(:server_log, tree && log(tree.name))
     |> assign(:server_error, nil)}
  end

  defp event("server_close", _params, socket),
    do: {:halt, assign(socket, :server_sheet, nil)}

  defp event(
         "server_run",
         %{"action" => action},
         %{assigns: %{server_sheet: %{} = tree}} = socket
       )
       when action in ~w(restart reseed off) do
    error =
      case DevScript.run(tree.path, tree.name, action) do
        :ok -> nil
        {:error, :no_script} -> "This repo has no bin/dev."
        {:error, :busy} -> "Something is already running for #{tree.name}."
      end

    {:halt, assign(socket, :server_error, error)}
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  # The open sheet's tree, from the latest servers read, and its log.
  defp reload(socket, repos \\ Servers.current()) do
    with %{path: path} <- socket.assigns.server_sheet,
         %{} = tree <- find(repos || [], path) do
      socket
      |> assign(:server_sheet, tree)
      |> assign(:server_log, log(tree.name))
    else
      _ -> socket
    end
  end

  defp find(repos, path), do: repos |> Enum.flat_map(& &1.trees) |> Enum.find(&(&1.path == path))

  # The last lines of the tree's log, without the terminal colours; nil without one.
  defp log(name) do
    path = Path.join(@log_dir, name <> ".log")

    with {:ok, %{size: size}} when size > 0 <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      from = max(size - 32_768, 0)
      {:ok, text} = :file.pread(file, from, size - from)
      File.close(file)

      text
      |> String.replace_invalid()
      |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
      |> String.split("\n", trim: true)
      # Reading from the middle of the file starts mid-line.
      |> Enum.drop(if from > 0, do: 1, else: 0)
      |> Enum.take(-@log_lines)
    else
      _ -> nil
    end
  end
end
