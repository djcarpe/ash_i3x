# The cluster tests need a distributed node, which needs epmd.
_ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

exclude =
  case Node.start(:"ash_i3x_test@127.0.0.1", :longnames) do
    {:ok, _} -> []
    {:error, _} -> [:cluster]
  end

ExUnit.start(exclude: exclude)
