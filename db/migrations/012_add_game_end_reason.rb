# How an arena game ended, as `arena --mixed` reports it (engine/arena.c):
# 'passes', 'limit' (the move limit), 'resign' (a bot resigned), 'time' (a
# network ran out of main time), or 'network_error' (one network could not
# be loaded, and lost). Games that failed are never stored, so their
# reasons never appear. Games recorded before this, and games not played
# through `arena --mixed`, have NULL.
Sequel.migration do
  change do
    alter_table(:games) do
      add_column :end_reason, String
    end
  end
end
