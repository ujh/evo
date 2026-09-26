# The feature genes each network carries (see the genes line in
# lib/ann.h): its feature set as the genes line writes it (`none`, or its
# groups comma-separated in their fixed order), its feature_step, and the
# weight of each move feature, NULL when the network's groups lack that
# feature. Every birth recorded from here on has them.
Sequel.migration do
  change do
    alter_table(:births) do
      add_column :features, String
      add_column :feature_step, Float
      add_column :fw_hane, Float
      add_column :fw_cut, Float
      add_column :fw_edge, Float
      add_column :fw_capture, Float
      add_column :fw_self_atari, Float
      add_column :fw_saves_atari, Float
      add_column :fw_near_last, Float
    end
  end
end
