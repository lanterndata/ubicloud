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
  def self.update_rhizome_from_local(vm, target_folder: "lantern", user: "lantern")
    update_rhizome(vm.sshable, target_folder, user)
  end
end
