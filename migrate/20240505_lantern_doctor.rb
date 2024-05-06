# frozen_string_literal: true

Sequel.migration do
  change do
    # doctor
    create_table(:lantern_doctor) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:lantern_resource) do
      add_foreign_key :doctor_id, :lantern_doctor, type: :uuid, null: true
    end
    # queries
    create_enum(:query_condition, %w[unknown healthy failed])
    create_enum(:query_type, %w[system udf])
    create_table(:lantern_doctor_query) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :parent_id, :lantern_doctor_query, type: :uuid
      foreign_key :doctor_id, :lantern_doctor, type: :uuid
      column :name, :text, null: true
      column :db_name, :text, null: true
      column :schedule, :text, null: true
      column :condition, :query_condition, null: false, default: "unknown"
      column :fn_label, :text, null: true
      column :sql, :text, null: true
      column :type, :query_type, null: false
      column :severity, :severity, default: "error", null: true
      column :last_checked, :timestamptz, null: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
