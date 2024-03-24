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
  semaphore :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules

  include Authorization::HyperTagMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/gcp_vm/#{name}"
  end

  include Authorization::TaggableMethods

  def path
    "/location/#{location}/gcp_vm/#{name}"
  end

  def ip4
    sshable&.host
  end

  def display_state
    return "deleting" if destroy_set?
    super
  end

  def mem_gib_ratio
    return 3.2 if arch == "arm64"
    8
  end

  def mem_gib
    (cores * mem_gib_ratio).to_i
  end

  def display_size
    # With additional product families, it is likely that we hit a
    # case where this conversion wouldn't work. We can use map or
    # when/case block at that time.

    # Define suffix integer as 2 * numcores. This coincides with
    # SMT-enabled x86 processors, to give people the right idea if
    # they compare the product code integer to the preponderance of
    # spec sheets on the web.
    #
    # With non-SMT processors, maybe we'll keep it that way too,
    # even though it doesn't describe any attribute about the
    # processor.  But, it does allow "standard-2" is compared to
    # another "standard-2" variant regardless of SMT,
    # e.g. "standard-2-arm", instead of making people interpreting
    # the code adjust the scale factor to do the comparison
    # themselves.
    #
    # Another weakness of this approach, besides it being indirect
    # in description of non-SMT processors, is having "standard-2"
    # be the smallest unit of product is also noisier than
    # "standard-1".
    "#{family}-#{cores * 2}"
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
