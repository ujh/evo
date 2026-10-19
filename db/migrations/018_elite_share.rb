# Elitism: the top elite_share of a generation's networks enter the next
# generation unchanged. An experiment with settings gets elite_share 0, no
# elitism, so it runs on as before. A fresh database is migrated before its
# settings are saved, so it gets none. Down deletes the setting.
Sequel.migration do
  up do
    settings = self[:settings]
    settings.insert(key: 'elite_share', value: '0') if settings.count.positive? && settings.where(key: 'elite_share').empty?
  end

  down do
    self[:settings].where(key: 'elite_share').delete
  end
end
