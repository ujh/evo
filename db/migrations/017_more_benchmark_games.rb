# The benchmark plays 100 games per opponent and per pair of panel bots
# instead of 20 and 40: with 20, most of a champion's games are against
# opponents it always beats or always loses to, and its rating stays
# uncertain by about ±80 Elo, too wide to tell one checkpoint from the next.
# An experiment still at the old defaults gets the new ones, and on its
# next start RunExperiment has its earlier checkpoints play the games they
# now lack (openings 10 to 49, and the bot games' 20 to 49); a value someone
# chose stays. Down restores the old defaults where the new ones are, the
# games played since stay.
Sequel.migration do
  up do
    settings = self[:settings]
    settings.where(key: 'benchmark_games', value: '20').update(value: '100')
    settings.where(key: 'benchmark_bot_games', value: '40').update(value: '100')
  end

  down do
    settings = self[:settings]
    settings.where(key: 'benchmark_games', value: '100').update(value: '20')
    settings.where(key: 'benchmark_bot_games', value: '100').update(value: '40')
  end
end
