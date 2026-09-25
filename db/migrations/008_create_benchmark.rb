# The benchmark: at checkpoint generations the generation's top network
# plays a fixed panel, so progress is measured apart from the tournament.
# `benchmark_opponents` is the panel, stored when the experiment is created
# like `opponents`, in the order the runner plays it. `kind` is 'bot' (an
# external program run by `command`), 'initial_champion' (the top network
# of generation 0), or 'previous_checkpoint' (the top network of the
# previous checkpoint); the network kinds have no command.
# `benchmark_games` holds one row per game, keyed by generation, opponent,
# opening, and the benchmarked network's color ('black' or 'white'), so a
# replayed game replaces its row. `network` is the benchmarked network's
# name, `opponent_network` the opposing network ("generation:name") for the
# network kinds, and `winner` is 'network', 'opponent', or nil for a draw or
# a failed game. The other columns are those of `games`.
Sequel.migration do
  change do
    create_table(:benchmark_opponents) do
      Integer :position, primary_key: true
      String :name, null: false, unique: true
      String :kind, null: false
      String :command
    end
    create_table(:benchmark_games) do
      Integer :generation, null: false
      String :opponent, null: false
      Integer :opening, null: false
      String :network_color, null: false
      String :network, null: false
      String :opponent_network
      String :winner
      String :failure
      Integer :length
      String :referee_result
      String :error_message
      String :stderr, text: true
      Float :duration
      Float :time_black
      Float :time_white
      primary_key %i[generation opponent opening network_color]
    end
  end
end
