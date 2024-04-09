# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:lantern_timeline) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :parent_id, :lantern_timeline, type: :uuid
      column :gcp_creds_b64, :text, collate: '"C"'
      column :service_account_name, :text, collate: '"C"'
      column :latest_backup_started_at, :timestamptz
      column :earliest_backup_completed_at, :timestamptz
    end
    alter_table(:lantern_server) do
      add_column :restore_target, :timestamptz, null: true
      add_foreign_key :timeline_id, :lantern_timeline, type: :uuid, null: true
    end
  end
  down do
    alter_table(:lantern_server) do
      drop_column :restore_target
      drop_column :timeline_id
    end
    drop_table(:lantern_timeline)
  end
end
