# What an experiment plays against and how it scores, stored when it is
# created so that later changes to the defaults in the code do not change a
# running experiment. `opponents` lists each bot, in the order the runner
# adds them, with the number of copies in the tournament. `scoring` holds
# the points for a win, a draw, and a bye, and the version of the scoring
# logic in RunGeneration (`rules`).
Sequel.migration do
  change do
    create_table(:opponents) do
      Integer :position, primary_key: true
      String :name, null: false, unique: true
      String :command, null: false
      Integer :copies, null: false
    end
    create_table(:scoring) do
      String :key, primary_key: true
      String :value, null: false
    end
  end
end
