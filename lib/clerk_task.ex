defmodule Clerk.Task do
  defmacro __using__(_opts) do
    quote do
      @behaviour Clerk.TaskBehaviour

      @impl true
      def init(args) do
        {:ok, args}
      end

      @impl true
      def nodes() do
        Node.list([:visible, :this])
      end

      defoverridable init: 1, nodes: 0
    end
  end
end
