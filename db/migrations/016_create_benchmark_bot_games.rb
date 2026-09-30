# The benchmark's bots also play each other, once per experiment rather
# than at every checkpoint, so the panel's bots are compared with each
# other as well as with the champions. `benchmark_bot_games` holds one row
# per game, keyed by the bot playing Black, the bot playing White (panel
# names), and the opening, so a replayed game replaces its row. No
# checkpoint owns a game: `generation` is only the checkpoint that happened
# to play it. `winner` is 'black', 'white', or nil for a draw or a failed
# game; the other columns are those of `benchmark_games`. An experiment
# with settings gets benchmark_bot_games 40 (games per pair of bots), so it
# plays them at the next checkpoint the runner enters. The existing
# `benchmark_games` rows are left as they are.
Sequel.migration do
  up do
    create_table(:benchmark_bot_games) do
      Integer :generation, null: false
      String :black, null: false
      String :white, null: false
      Integer :opening, null: false
      String :winner
      String :failure
      Integer :length
      String :referee_result
      String :error_message
      String :stderr, text: true
      Float :duration
      Float :time_black
      Float :time_white
      primary_key %i[black white opening]
    end
    settings = self[:settings]
    settings.insert(key: 'benchmark_bot_games', value: '40') if settings.count.positive? && settings.where(key: 'benchmark_bot_games').empty?
  end

  down do
    drop_table(:benchmark_bot_games)
    self[:settings].where(key: 'benchmark_bot_games').delete
  end
end
