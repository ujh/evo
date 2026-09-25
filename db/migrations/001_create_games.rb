# One row per scored game. A game replayed after a crash has the same key and
# replaces its row.
Sequel.migration do
  change do
    create_table(:games) do
      Integer :generation, null: false
      Integer :round, null: false
      String :black, null: false
      String :white, null: false
      TrueClass :black_external, null: false
      TrueClass :white_external, null: false
      String :winner
      String :failure
      Integer :length
      String :referee_result
      String :error_message
      String :stderr, text: true
      String :sgf, text: true
      primary_key %i[generation round black white]
    end
  end
end
