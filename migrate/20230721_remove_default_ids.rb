# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:strand) do
      set_column_default :id, nil
    end

    alter_table(:semaphore) do
      set_column_default :id, nil
    end

    alter_table(:sshable) do
      set_column_default :id, nil
    end

    alter_table(:project) do
      set_column_default :id, nil
    end

    alter_table(:access_tag) do
      set_column_default :id, nil
    end

    alter_table(:access_policy) do
      set_column_default :id, nil
    end

    alter_table(:accounts) do
      set_column_default :id, nil
    end

    alter_table(:account_authentication_audit_logs) do
      set_column_default :id, nil
    end

    alter_table(:account_jwt_refresh_keys) do
      set_column_default :id, nil
    end
  end
end
