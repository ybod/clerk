defmodule ClerkTest.DoubleChainedTestTask do
  @moduledoc false

  use Clerk.PeriodicTask

  @impl true
  def execute(%{caller: caller} = state) do
    send(caller, {:double_chained_task_executed, node()})

    {:ok, state}
  end
end
