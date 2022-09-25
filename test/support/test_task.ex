defmodule ClerkTest.TestTask do
  @moduledoc false

  use Clerk.Task

  @impl true
  def execute(%{caller: caller} = state) do
    execution_time =
      if Map.has_key?(state, :task_start_time) do
        System.convert_time_unit(
          System.monotonic_time() - state.task_start_time,
          :native,
          :millisecond
        )
      else
        nil
      end

    send(caller, {:executed, node(), execution_time})

    {:ok, state}
  end
end
