# A checkpoint's benchmark plays the last `benchmark_champions` checkpoints'
# top networks instead of only the previous one. The panel row of kind
# 'previous_checkpoint' becomes PastChampions of kind 'past_champions', and
# an experiment with settings gets benchmark_champions 10, so it runs on as
# new experiments do. A game already played against the previous checkpoint
# is renamed to that champion's name, GenNChampion, N the generation in its
# opponent_network ("generation:name"), which is what the new panel plays.
# Down turns them back and refuses once a checkpoint has played a champion
# older than its previous checkpoint, which the old panel cannot hold.
Sequel.migration do
  up do
    panel = self[:benchmark_opponents]
    old = panel.where(kind: 'previous_checkpoint').get(:name)
    if old
      panel.where(kind: 'previous_checkpoint').update(name: 'PastChampions', kind: 'past_champions')
      games = self[:benchmark_games]
      games.where(opponent: old).select_map(:opponent_network).uniq.each do |network|
        source = Integer(network.split(':', 2).first, 10)
        games.where(opponent: old, opponent_network: network).update(opponent: "Gen#{source}Champion")
      end
    end
    settings = self[:settings]
    settings.insert(key: 'benchmark_champions', value: '10') if settings.count.positive? && settings.where(key: 'benchmark_champions').empty?
  end

  down do
    settings = self[:settings]
    keep_every = settings.where(key: 'keep_every').get(:value)
    panel = self[:benchmark_opponents]
    games = self[:benchmark_games]
    # The network opponents other than generation 0's champion.
    champions = games.exclude(opponent_network: nil).exclude(opponent: panel.where(kind: 'initial_champion').select(:name))
    champions.select_map(%i[generation opponent]).uniq.each do |generation, opponent|
      previous = keep_every && "Gen#{generation - Integer(keep_every, 10)}Champion"
      raise "generation #{generation} played #{opponent}, which is not its previous checkpoint" unless opponent == previous

      games.where(generation:, opponent:).update(opponent: 'PreviousCheckpoint')
    end
    panel.where(kind: 'past_champions').update(name: 'PreviousCheckpoint', kind: 'previous_checkpoint')
    settings.where(key: 'benchmark_champions').delete
  end
end
