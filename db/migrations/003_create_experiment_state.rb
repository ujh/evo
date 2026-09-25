# The experiment's settings and each generation's tournament state, which
# used to live in settings.json and GEN/data.json. The rankings table from
# migration 002 holds the live standings: the ranking as it stands after the
# last scored game, and the final ranking once the generation is done.
Sequel.migration do
  change do
    create_table(:settings) do
      String :key, primary_key: true
      String :value, text: true, null: false
    end

    create_table(:generations) do
      Integer :generation, primary_key: true
      Integer :round, null: false
      TrueClass :setup_complete, null: false
    end

    create_table(:players) do
      Integer :generation, null: false
      String :name, null: false
      String :command, text: true, null: false
      TrueClass :external, null: false
      primary_key %i[generation name]
    end

    # Games still to play in the current round, in pairing order. A game
    # without white is the bye.
    create_table(:pending_games) do
      Integer :generation, null: false
      Integer :position, null: false
      String :black, null: false
      String :white
      primary_key %i[generation position]
    end
  end
end
