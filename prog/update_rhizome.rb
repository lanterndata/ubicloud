# frozen_string_literal: true

class Prog::UpdateRhizome < Prog::Base
  subject_is :sshable

  def user
    @user ||= frame.fetch("user", "root")
  end

  label def start
    hop_setup
  end

  label def setup
    pop "rhizome updated" if retval&.dig("msg") == "installed rhizome"
    push Prog::InstallRhizome, {"target_folder" => frame["target_folder"]}
  end
end
