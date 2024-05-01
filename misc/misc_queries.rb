# frozen_string_literal: true

class MiscQueries
  def self.update_collation_on_all_databases
    # https://postgresql.verite.pro/blog/2018/08/27/glibc-upgrade.html
    # We didn't need to update rebuild indexes this time as we didn't have any indexes with collation coming from libc
    resources = LanternResource.all
    resources.each do |resource|
      update_collation resource
    end
  end

  def self.update_collation(resource)
    all_dbs = resource.representative_server.run_query("SELECT datname from pg_database WHERE datname != 'template0'").split("\n")
    all_dbs.each do |db|
      resource.representative_server.run_query("ALTER DATABASE #{db} REFRESH COLLATION VERSION")
    end
  end
end
