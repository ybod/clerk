defmodule Clerk.TaskBehaviour do
  @moduledoc """
  Clerk Periodic Task interface functions
  """
  @callback init(args :: term()) :: :ok | {:ok, state :: term()}

  @callback execute(state :: term()) :: :ok | {:ok, state :: term()}

  @callback nodes() :: [] | [node()]
end
