# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies

  many_to_many :gcp_vms, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :lantern_servers, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id

  dataset_module Authorization::Dataset

  plugin :association_dependencies, access_tags: :destroy, access_policies: :destroy # , gcp_vms: :destroy, lantern_servers: :destroy

  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "project/#{ubid}"
  end

  include Authorization::TaggableMethods

  def user_ids
    access_tags_dataset.where(hyper_tag_table: Account.table_name.to_s).select_map(:hyper_tag_id)
  end

  def has_valid_payment_method?
    true
    # return true unless Config.stripe_secret_key
    # !!billing_info&.payment_methods&.any?
  end

  def path
    "/project/#{ubid}"
  end

  def has_resources
    access_tags_dataset.exclude(hyper_tag_table: [Account.table_name.to_s, Project.table_name.to_s, AccessTag.table_name.to_s]).count > 0
  end

  def soft_delete
    DB.transaction do
      access_tags_dataset.destroy
      access_policies_dataset.destroy
      # We still keep the project object for billing purposes.
      # These need to be cleaned up manually once in a while.
      # Don't forget to clean up billing info and payment methods.
      update(visible: false)
    end
  end

  def self.feature_flag(*flags)
    flags.map(&:to_s).each do |flag|
      define_method :"set_#{flag}" do |value|
        update(feature_flags: feature_flags.merge({flag => value}))
      end

      define_method :"get_#{flag}" do
        feature_flags[flag]
      end
    end
  end
end
