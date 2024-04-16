require_relative "../loader"

def continue_story
  puts "press any key to continue or 'q' to exit"
  char = STDIN.getch
  puts "            \r"
  if char == "q"
    raise "Cancelled"
  end
end

def setup_user(username, sshable, unix_user, key_data)
    Util.rootish_ssh(sshable.host, unix_user, key_data, <<SH)
set -ueo pipefail
sudo apt update && sudo apt-get -y install ruby-bundler
sudo userdel -rf #{username} || true
sudo adduser --disabled-password --gecos '' #{username}
echo '#{username} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-#{username}
sudo install -d -o #{username} -g #{username} -m 0700 /home/#{username}/.ssh
sudo install -o #{username} -g #{username} -m 0600 /dev/null /home/#{username}/.ssh/authorized_keys
echo #{sshable.keys.map(&:public_key).join("\n").shellescape} | sudo tee /home/#{username}/.ssh/authorized_keys > /dev/null
SH
end

def install_rhizome(sshable, target_folder: "lantern", user: "lantern")
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
  puts "installed rhizome"
end


def migrate_existing_db(
  location: "us-central1",
  name: "db-name",
  app_env: "production",
  org_id: 0,
  superuser_password: "postgres",
  parent_id: nil,
  restore_target: nil,
  db_name: "postgres",
  db_user: "postgres",
  db_user_password: "postgres",
  repl_user: "repl_user",
  repl_password: "repl_password",
  vm_name: nil,
  vm_host: nil,
  unix_user: "lantern",
  family: "n1-standard",
  cores: 16,
  arch: "x64",
  storage_size_gib: 500,
  lantern_version: "0.2.4",
  extras_version: "0.1.4",
  minor_version: "3",
  timeline_access: "push",
  representative_at: Time.new,
  domain: nil,
  root_user: "lantern"
)
  DB.transaction do
    project = Project.first
    project_id = project.id
    target_vm_size = "#{family}-#{cores}"
    target_storage_size_gib = storage_size_gib
    ha_type = LanternResource::HaType::NONE
    # LANTERN RESOURCE
    lantern_resource = LanternResource.create_with_id(
      project_id: project_id, location: location, name: name, org_id: org_id, app_env: app_env,
      superuser_password: superuser_password, ha_type: ha_type, parent_id: parent_id,
      restore_target: restore_target, db_name: db_name, db_user: db_user,
      db_user_password: db_user_password, repl_user: repl_user, repl_password: repl_password
    )
    lantern_resource.associate_with_project(project)
    puts "Lantern resource created"

    # VM and SSHABLE
    ssh_key = SshKey.generate
    vm = GcpVm.create_with_id(
      name: vm_name,
      public_key: ssh_key.public_key,
      unix_user: unix_user,
      family: family, cores: cores, location: location,
      boot_image: "ubuntu-2204-jammy-v20240319", arch: arch, storage_size_gib: storage_size_gib)
    sshable = Sshable.create(unix_user: unix_user, host: vm_host, raw_private_key_1: ssh_key.keypair) {
      _1.id = vm.id
    }

    puts "VM created"

    # LANTERN TIMELINE
    lantern_timeline = LanternTimeline.create_with_id(
      parent_id: nil,
      gcp_creds_b64: Config.gcp_creds_walg_b64
    )

    puts "Lantern Timeline created"

    # LANTERN SERVER
    lantern_server = LanternServer.create_with_id(
      resource_id: lantern_resource.id,
      lantern_version: lantern_version,
      extras_version: extras_version,
      minor_version: minor_version,
      target_vm_size: target_vm_size,
      target_storage_size_gib: target_storage_size_gib,
      vm_id: vm.id,
      timeline_access: timeline_access,
      timeline_id: lantern_timeline.id,
      representative_at: representative_at,
      synchronization_status: representative_at ? "ready" : "catching_up",
      domain: domain
    )
    puts "Lantern Server created"

    # Strands
    puts "Add the following public key to gcp_vm under #{root_user}"
    puts "#{ssh_key.public_key}"
    continue_story

    key_data = sshable.keys.map(&:private_key)

    if root_user != "lantern"
    # Setup lantern user
    setup_user("lantern", sshable, root_user, key_data)
    puts "lantern user created"
    end

    # Setup Rhizome user
    setup_user("rhizome", sshable, unix_user, key_data)
    puts "rhizome user created"

    install_rhizome(sshable)
    puts "rhizome installed"
    Strand.create(prog: "GcpVm::Nexus", label: "wait") { _1.id = vm.id }
    Strand.create(prog: "Lantern::LanternResourceNexus", label: "wait") { _1.id = lantern_resource.id }
    Strand.create(prog: "Lantern::LanternServerNexus", label: "wait") { _1.id = lantern_server.id }
    puts "strands created"

    walg_config = lantern_timeline.generate_walg_config
    puts "Updating WALG_GS_PREFIX to #{walg_config[:walg_gs_prefix]} to enable backups..."
    continue_story
    sshable.cmd("sudo lantern/bin/update_env", stdin: JSON.generate([
      ["WALG_GS_PREFIX", walg_config[:walg_gs_prefix]],
      ["GOOGLE_APPLICATION_CREDENTIALS_WALG_B64", walg_config[:gcp_creds_b64]],
    ]))
    Strand.create(prog: "Lantern::LanternTimelineNexus", label: "wait") { _1.id = lantern_timeline.id }
    puts "walg prefix updated"
  end
end
