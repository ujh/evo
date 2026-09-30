# The time per player per game in seconds instead of whole minutes: the
# settings row game_length N becomes game_seconds N x 60, so an experiment
# plays as before. Data only; a database created after this has no
# game_length row. Down turns the seconds back into minutes and refuses a
# value that is not whole minutes.
Sequel.migration do
  up do
    settings = self[:settings]
    minutes = settings.where(key: 'game_length').get(:value)
    if minutes
      settings.where(key: 'game_length').delete
      settings.insert(key: 'game_seconds', value: (Integer(minutes, 10) * 60).to_s)
    end
  end

  down do
    settings = self[:settings]
    seconds = settings.where(key: 'game_seconds').get(:value)
    if seconds
      minutes, rest = Integer(seconds, 10).divmod(60)
      raise "game_seconds #{seconds} is not a whole number of minutes, so game_length cannot hold it" unless rest.zero?

      settings.where(key: 'game_seconds').delete
      settings.insert(key: 'game_length', value: minutes.to_s)
    end
  end
end
