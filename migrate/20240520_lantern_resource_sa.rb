# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_resource) do
      add_column :gcp_creds_b64, :text, collate: '"C"'
      add_column :service_account_name, :text, collate: '"C"'
    end

    sql = <<SQL
     UPDATE lantern_resource lr
     SET gcp_creds_b64 = lt.gcp_creds_b64,
         service_account_name = lt.service_account_name
     FROM lantern_server ls JOIN lantern_timeline lt ON ls.timeline_access='push' AND ls.timeline_id=lt.id WHERE ls.resource_id = lr.id;
SQL
    run sql

    alter_table(:lantern_timeline) do
      drop_column :service_account_name
    end
  end
end
