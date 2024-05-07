# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:lantern_doctor_query) do
      add_column :response_type, :text, null: false, default: "bool"
    end
  end
  down do
    alter_table(:lantern_doctor_query) do
      drop_column :response_type
    end
  end
end
