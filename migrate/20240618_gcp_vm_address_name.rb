# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:gcp_vm) do
      add_column :address_name, :text, collate: '"C"'
    end
    run "UPDATE gcp_vm SET address_name=name || '-addr'"
  end
end
