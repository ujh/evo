# How long each game took: duration is the wall-clock seconds of the whole
# gogui-twogtp run, time_black and time_white the seconds each player spent
# on genmove (twogtp's TIME_B and TIME_W). The rest of the duration is the
# referee, the JVM, starting the programs, and the other GTP commands, plus a
# 3 s wait twogtp adds when a player crashed. Games recorded before this have
# none.
Sequel.migration do
  change do
    alter_table(:games) do
      add_column :duration, Float
      add_column :time_black, Float
      add_column :time_white, Float
    end
  end
end
