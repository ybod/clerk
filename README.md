# Clerk

Simple manager for global periodic tasks

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `clerk` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:clerk, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/clerk](https://hexdocs.pm/clerk).

## Testing

Testing over local distributed nodes cluster requires **epmd** daemon to be running. You can start **epmd** via `epmd -daemon` command and stop with `epmd -kill`.