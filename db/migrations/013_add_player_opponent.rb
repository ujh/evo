# Which opponent (the `opponents` row's name) each copy of a bot in a
# generation's `players` is, so the tournament can keep two copies of one
# bot from playing each other, also after a resume reloads the state.
# Networks have NULL. Rows written before this have NULL too.
Sequel.migration do
  change do
    alter_table(:players) do
      add_column :opponent, String
    end
  end
end
