# frozen_string_literal: true

require_relative "../model"

class GcpVm < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id

  plugin :association_dependencies, sshable: :destroy

  dataset_module Pagination
  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  include DisplayStatusMethods
  semaphore :destroy, :start_vm, :stop_vm, :update_storage, :update_size

  include Authorization::HyperTagMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/gcp_vm/#{name}"
  end

  include Authorization::TaggableMethods

  def path
    "/location/#{location}/gcp_vm/#{name}"
  end

  def host
    sshable&.host
  end

  def mem_gib_ratio
    return 3.2 if arch == "arm64"
    8
  end

  def mem_gib
    (cores * mem_gib_ratio).to_i
  end

  def display_size
    "#{family}-#{cores}"
  end

  # Various names in linux, like interface names, are obliged to be
  # short, so truncate the ubid. This does introduce the spectre of
  # collisions.  When the time comes, we'll have to ensure it doesn't
  # happen on a single host, pushing into the allocation process.
  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def inhost_name
    self.class.ubid_to_name(UBID.from_uuidish(id))
  end

  def self.redacted_columns
    super + [:public_key]
  end
end
