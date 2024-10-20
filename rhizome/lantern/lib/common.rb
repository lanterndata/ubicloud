# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../../common/lib/util"

$workdir = "/var/lib/lantern"
$datadir = "/var/lib/lantern-data"
$compose_file = "#{$workdir}/docker-compose.yaml"
$env_file = "#{$workdir}/.env"
$pg_mount_path = "#{$workdir}/pg"
$container_name = "lantern-postgresql-1"

def configure_gcr(gcp_creds_gcr_b64, container_image)
  r "echo #{gcp_creds_gcr_b64} | base64 -d | sudo docker login -u _json_key --password-stdin https://gcr.io"
  r "sudo docker pull #{container_image}"
end

def update_extensions_in_sql
  all_dbs = (r "docker compose -f #{$compose_file} exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'").strip!.split("\n")
  tmp_cmd = ""
  all_dbs.each do |db|
    tmp_cmd += "docker compose -f #{$compose_file} exec postgresql psql -U postgres -f /lantern-init.sql #{db} \n"
  end

  # There was a strange issue with open3
  # If for example the database count would be >300 it might fail without error
  # But if we put all the commands in one bash file and execute that file it would succeed

  File.write("/tmp/update_extensions_in_sql.sh", tmp_cmd)
  $stdout.puts r "bash /tmp/update_extensions_in_sql.sh"
  $stdout.puts r "rm -rf /tmp/update_extensions_in_sql.sh"
end

def wait_for_pg
  until r "docker exec #{$container_name} pg_isready -U postgres 2>/dev/null;"
    sleep 1
  end
end

def run_database(container_image)
  # Run database
  volume_mount = "#{$pg_mount_path}:/opt/bitnami/postgresql"
  # Copy postgres fs to host to mount
  r "sudo rm -rf #{$pg_mount_path}"
  data = YAML.load_file $compose_file
  data["services"]["postgresql"]["volumes"] = data["services"]["postgresql"]["volumes"].select { |i| i != volume_mount }
  File.open($compose_file, "w") { |f| YAML.dump(data, f) }
  r "sudo docker rm -f tc 2>/dev/null || true"
  r "sudo docker create --name tc #{container_image}"
  r "sudo docker cp tc:/opt/bitnami/postgresql #{$pg_mount_path}"
  r "sudo docker rm tc"
  r "sudo chown -R 1001:1001 #{$pg_mount_path}"
  # Mount extension dir, so we can make automatic updates from host
  data["services"]["postgresql"]["volumes"].push(volume_mount)
  File.open($compose_file, "w") { |f| YAML.dump(data, f) }
  r "sudo docker compose -f #{$compose_file} up -d -t 60"
end

def restart_if_needed
  r "docker compose -f #{$compose_file} up -d -t 60"
end

def force_restart
  r "docker compose -f #{$compose_file} down -t 60 && docker compose -f #{$compose_file} up -d"
end

def append_env(env_arr)
  existing_env = begin
    File.readlines($env_file).grep(/^\w+=.*/).map { |line| line.chomp.split("=", 2) }.to_h
  rescue
    {}
  end

  combined_env = existing_env.merge(env_arr.to_h) do |key, old_val, new_val|
    new_val
  end

  File.open($env_file, "w") { |f| combined_env.each { |key, value| f.puts "#{key}=#{value}" } }
end

def configure_tls(domain, email, dns_token, dns_zone_id, provider)
  puts "Configuring TLS for domain #{domain}"
  r "curl -s https://get.acme.sh | sh -s email=#{email}"
  env = if provider == "dns_cf"
    "CF_Token='#{dns_token}' CF_Zone_ID='#{dns_zone_id}'"
  else
    "GOOGLEDOMAINS_ACCESS_TOKEN='#{dns_token}'"
  end

  r "#{env} /root/.acme.sh/acme.sh --server letsencrypt --issue --dns #{provider} -d #{domain}"
  reload_cmd = "sudo docker compose -f #{$compose_file} exec postgresql psql -U postgres -c 'SELECT pg_reload_conf()' && sudo docker compose -f #{$compose_file} exec postgresql psql -p6432 -U postgres pgbouncer -c RELOAD"
  r "/root/.acme.sh/acme.sh --install-cert -d #{domain} --key-file #{$datadir}/server.key  --fullchain-file #{$datadir}/server.crt --reloadcmd \"#{reload_cmd}\""
  r "sudo chown 1001:1001 #{$datadir}/server.key"
  r "sudo chown 1001:1001 #{$datadir}/server.crt"
  r "sudo chmod 600 #{$datadir}/server.key"

  append_env([
    ["POSTGRESQL_ENABLE_TLS", "yes"],
    ["POSTGRESQL_TLS_CERT_FILE", "/bitnami/postgresql/server.crt"],
    ["POSTGRESQL_TLS_KEY_FILE", "/bitnami/postgresql/server.key"]
  ])

  restart_if_needed
end

def calculate_memory_sizes
  total_ram = (r "free -tk | awk 'NR == 2 {print $2}'")
  # Calculate 95% of the total RAM in kilobytes, but reserve at least 500mb
  # If the subtraction will underflow we will set the limit to 500mb
  shared_buf_mb = [(total_ram.to_i * 0.95 / 1024).round, total_ram.to_i / 1024 - 500].min.clamp(500..)
  # Calculate 50% of the total RAM in kilobytes
  shm_size_mb = (total_ram.to_i * 0.5 / 1024).round
  mem_limit_buf = "#{shared_buf_mb}MB"
  mem_limit_shm = "#{shm_size_mb}MB"

  {shm_size: mem_limit_shm, shared_bufs: mem_limit_buf}
end
