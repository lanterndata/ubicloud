# frozen_string_literal: true

class MiscQueries
  def self.update_collation_on_all_databases
    # https://postgresql.verite.pro/blog/2018/08/27/glibc-upgrade.html
    # We didn't need to update rebuild indexes this time as we didn't have any indexes with collation coming from libc
    resources = LanternResource.all
    resources.each do |resource|
      resource.representative_server.run_query("ALTER DATABASE template1 REFRESH COLLATION VERSION")
    end
  end
end
