# frozen_string_literal: true

def update_rhizome(sshable, target_folder, user)
  tar = StringIO.new
  Gem::Package::TarWriter.new(tar) do |writer|
    base = Config.root + "/rhizome"
    Dir.glob(["Gemfile", "Gemfile.lock", "common/**/*", "#{target_folder}/**/*"], base: base).map do |file|
      full_path = base + "/" + file
      stat = File.stat(full_path)
      if stat.directory?
        writer.mkdir(file, stat.mode)
      elsif stat.file?
        writer.add_file(file, stat.mode) do |tf|
          File.open(full_path, "rb") do
            IO.copy_stream(_1, tf)
          end
        end
      else
        # :nocov:
        fail "BUG"
        # :nocov:
      end
    end
  end
  payload = tar.string.freeze
  sshable.cmd("tar xf -", stdin: payload)

  sshable.cmd("bundle config set --local path vendor/bundle")
  sshable.cmd("bundle install")
  puts "updated rhizome"
end

class MiscOperations
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

  def self.active_queries(resource_name)
    LanternResource[name: resource_name].representative_server.run_query("SELECT pid, query FROM pg_stat_activity")
  end

  def self.update_rhizome_from_local(vm, target_folder: "lantern", user: "lantern")
    update_rhizome(vm.sshable, target_folder, user)
  end

  def self.docker_logs(resource_name, tail: 10)
    LanternResource[name: resource_name].representative_server.vm.sshable.cmd("sudo docker logs lantern-postgresql-1 --tail #{tail} -f")
  end

  def self.docker_env(resource_name)
    LanternResource[name: resource_name].representative_server.vm.sshable.cmd("sudo cat /var/lib/lantern/.env")
  end

  def self.mem_info(resource_name)
    LanternResource[name: resource_name].representative_server.vm.sshable.cmd("free -mh")
  end

  def self.kill_query(resource_name, pid)
    LanternResource[name: resource_name].representative_server.run_query("SELECT pg_terminate_backend(#{pid})")
  end

  def self.task_logs(resource_name, task_name, poll: false)
    loop do
      puts LanternResource[name: resource_name].representative_server.vm.sshable.cmd("common/bin/daemonizer --logs #{task_name}")
      break if !poll
      sleep(2)
    end
  end

  def self.task_status(resource_name, task_name, poll: false)
    loop do
      puts LanternResource[name: resource_name].representative_server.vm.sshable.cmd("common/bin/daemonizer --check #{task_name}")
      break if !poll
      sleep(2)
    end
  end

  def self.query_on_db(vm, db_name, query)
    vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -U postgres -t --csv #{db_name}", stdin: query)
  end

  def self.reindex_all_concurrently(resource_name, disable_indexes: false)
    serv = LanternResource[name: resource_name].representative_server
    all_dbs = serv.vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'").strip.split("\n")
    command_list = []
    all_dbs.each do |db|
      db_name = db.strip
      indexes = MiscOperations.query_on_db(serv.vm, db_name, "SELECT n.nspname::text || '.' || i.relname
                              FROM pg_class t
                              JOIN pg_index ix ON t.oid = ix.indrelid
                              JOIN pg_class i ON i.oid = ix.indexrelid
                              JOIN pg_am a ON i.relam = a.oid
                              JOIN pg_namespace n ON n.oid = i.relnamespace
                              WHERE a.amname = 'lantern_hnsw';").strip.split("\n")

      if !indexes.empty?
        queries = []
        indexes.each {
          schema, idx = _1.split(".")
          queries.push("REINDEX INDEX CONCURRENTLY \\\"#{schema}\\\".\\\"#{idx}\\\";")
          if disable_indexes
            queries.push("UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = quote_ident('#{_1}')::regclass::oid;")
          end
        }

        queries.map do |query|
          command_list.push("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -U postgres #{db_name} -c \"#{query}\"")
        end
      end
    end
    command = command_list.join("\n")

    serv.vm.sshable.cmd("cp /dev/stdin /tmp/reindex_all_concurrently.sh && chmod +x /tmp/reindex_all_concurrently.sh", stdin: command)
    serv.vm.sshable.cmd("common/bin/daemonizer 'sudo /tmp/reindex_all_concurrently.sh' reindex_all_concurrently")

    task_logs resource_name, "reindex_all_concurrently"
  end

  def self.get_all_lantern_indexes(resource_name)
    serv = LanternResource[name: resource_name].representative_server
    all_dbs = serv.vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'").strip.split("\n")
    all_indexes = []
    all_dbs.each do |db|
      db_name = db.strip
      indexes = MiscOperations.query_on_db(serv.vm, db_name, "SELECT i.relname::text
                              FROM pg_class t
                              JOIN pg_index ix ON t.oid = ix.indrelid
                              JOIN pg_class i ON i.oid = ix.indexrelid
                              JOIN pg_am a ON i.relam = a.oid
                              JOIN pg_namespace n ON n.oid = i.relnamespace
                              WHERE a.amname = 'lantern_hnsw';").strip.split("\n")
      all_indexes += indexes
    end
    all_indexes
  end

  def self.add_lantern_doctor_to_all
    LanternResource.all.each {
      lantern_doctor = Prog::Lantern::LanternDoctorNexus.assemble
      _1.update(doctor_id: lantern_doctor.id)
    }
  end
end
