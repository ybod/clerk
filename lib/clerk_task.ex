defmodule Clerk.PeriodicTask do
  defmacro __using__(_opts) do
    quote do
      @behaviour Clerk.PeriodicTaskBehaviour

      @impl true
      def init(params) do
        {:ok, params}
      end

      @impl true
      def nodes() do
        Node.list()
      end

      defoverridable init: 1, nodes: 0
    end
  end
end
