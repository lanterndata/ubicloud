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

  def self.run_script_daemonized(resource_name, filename, task_name)
    serv = LanternResource[name: resource_name].representative_server
    serv.vm.sshable.cmd("common/bin/daemonizer 'sudo #{filename}' #{task_name}")

    task_logs resource_name, task_name.to_s
  end

  def self.create_all_indexes_concurrently_script(resource_name, filename)
    serv = LanternResource[name: resource_name].representative_server
    all_dbs = serv.vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'").strip.split("\n")
    command_list = []
    all_dbs.each do |db|
      db_name = db.strip
      indexes = MiscOperations.query_on_db(serv.vm, db_name, "SELECT indexdef FROM pg_indexes WHERE indexdef ILIKE '%lantern_hnsw%';").strip.split("\n")

      if !indexes.empty?
        queries = []
        indexes.each {
          queries.push(_1.gsub(/create\s+index/i, "CREATE INDEX CONCURRENTLY")[1..-2])
        }

        queries.map do |query|
          command_list.push("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -U postgres #{db_name} -c \"#{query}\"")
        end
      end
    end
    command = command_list.join("\n")

    serv.vm.sshable.cmd("cp /dev/stdin #{filename} && chmod +x #{filename}", stdin: command)
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
            queries.push("UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = quote_ident('#{idx}')::regclass::oid;")
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

  def self.add_lantern_doctor(resource_name)
    res = LanternResource[name: resource_name]
    return if !res.doctor.nil?
    lantern_doctor = Prog::Lantern::LanternDoctorNexus.assemble
    res.update(doctor_id: lantern_doctor.id)
  end

  def self.add_lantern_doctor_to_all
    LanternResource.all.each {
      if _1.doctor.nil?
        lantern_doctor = Prog::Lantern::LanternDoctorNexus.assemble
        _1.update(doctor_id: lantern_doctor.id)
      end
    }
  end

  def self.create_image(lantern_version: "0.2.7", extras_version: "0.1.5", minor_version: "1", vm: nil)
    gcp_api = Hosting::GcpApis.new
    name = "ubuntu-lantern-#{lantern_version.tr(".", "-")}-extras-#{extras_version.tr(".", "-")}-minor-#{minor_version}"
    container_image = "#{Config.gcr_image}:lantern-#{lantern_version}-extras-#{extras_version}-minor-#{minor_version}"
    description = "Lantern Image with cached: Lantern #{lantern_version}, extras: #{extras_version}, minor: #{minor_version} - Created At #{Time.new}"

    if vm.nil?
      vm = Prog::GcpVm::Nexus.assemble_with_sshable("lantern", Project.first.id, name: "imagecreation-machine", storage_size_gib: 10)

      # wait vm available
      loop do
        break if Strand[vm.id].label == "wait"
        sleep 10
      end

      vm = GcpVm[vm.id]
      puts "VM Created"
    end

    key_data = vm.sshable.keys.map(&:private_key)
    Util.rootish_ssh(vm.sshable.host, "lantern", key_data, <<SH)
set -euo pipefail
sudo apt update && sudo apt-get -y install software-properties-common make ruby-bundler
curl -fsSL https://get.docker.com > /tmp/get-docker.sh
chmod +x /tmp/get-docker.sh
/tmp/get-docker.sh
rm -rf /tmp/get-docker.sh
sudo sed -i 's/ulimit -Hn/ulimit -n/' /etc/init.d/docker
sudo service docker restart
echo #{Config.gcp_creds_gcr_b64} | base64 -d | sudo docker login -u _json_key --password-stdin https://gcr.io
sudo docker pull #{container_image}
sudo docker logout
history -cw
SH
    puts "Dependencies installed"

    vm.incr_stop_vm
    # wait vm stopped
    loop do
      break if GcpVm[vm.id].display_state == "stopped"
      sleep 10
    end

    puts "VM stopped creating image"
    gcp_api.create_image(name: name, vm_name: vm.name, zone: "#{vm.location}-a", description: description)
    puts "Image created"
    vm.incr_destroy
  end
end
