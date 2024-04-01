# frozen_string_literal: true

require "net/ssh"
require "openssl"

module Util
  # A minimal, non-cached SSH implementation.
  #
  # It must log into an account that can escalate to root via "sudo,"
  # which typically includes the "root" account reflexively.  The
  # ssh-agent is employed by default here, since personnel are thought
  # to be involved with preparing new VmHosts.
  def self.rootish_ssh(host, user, keys, cmd)
    Net::SSH.start(host, user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: keys,
        use_agent: Config.development?)) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Ssh command failed: #{ret}" unless ret.exitstatus.zero?
      ret
    end
  end

  def self.exception_to_hash(ex)
    {exception: {message: ex.message, class: ex.class.to_s, backtrace: ex.backtrace, cause: ex.cause.inspect}}
  end

  def self.safe_write_to_file(filename, content)
    FileUtils.mkdir_p(File.dirname(filename))
    temp_filename = filename + ".tmp"
    File.open("#{temp_filename}.lock", File::RDWR | File::CREAT) do |lock_file|
      lock_file.flock(File::LOCK_EX)
      File.write(temp_filename, content)
      File.rename(temp_filename, filename)
    end
  end
end
