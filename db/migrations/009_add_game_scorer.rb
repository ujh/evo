# Who decided each game: 'gnugo' for a GoGui game refereed by GNU Go,
# 'tromp_taylor' for an arena game, counted by Tromp-Taylor rules in the
# arena itself. Every game recorded before this was a GoGui game, so the
# default fills 'gnugo' into those rows. ExperimentDatabase#record requires
# the scorer, so new rows never fall back on the default.
Sequel.migration do
  change do
    alter_table(:games) do
      add_column :scorer, String, null: false, default: 'gnugo'
    end
  end
end
