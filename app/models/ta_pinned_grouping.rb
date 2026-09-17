# frozen_string_literal: true

# A custom field an administrator has pinned as a permanent grouping tab, via the
# "Show as a grouping tab in Time Analytics" checkbox on the custom field form
# (Administration -> Custom fields).
#
# A pinned field behaves like the built-in Issue/Activity/Project and Members/Activity/Project
# tabs: it is rendered server-side on every dashboard for every user, and cannot be removed from
# the tab strip by the viewer. That is the whole difference from a tab added with the "+" control,
# which lives in sessionStorage and belongs to one browser tab.
#
# Pinning only records the administrator's intent. Whether the field is actually groupable for a
# given viewer is still decided by RedmineTimeAnalytics::GroupableFieldRegistry, so role
# visibility, "Used as a filter" and the single-value format rule all continue to apply.
class TaPinnedGrouping < ActiveRecord::Base
  belongs_to :custom_field

  validates :custom_field_id, presence: true, uniqueness: true

  scope :ordered, -> { order(:position, :id) }

  class << self
    # Custom field ids pinned by an administrator, in display order.
    def pinned_custom_field_ids
      ordered.pluck(:custom_field_id)
    end

    def pinned?(custom_field)
      return false if custom_field.nil?

      exists?(custom_field_id: custom_field.id)
    end

    # Adds or removes a pin. Called from the custom field form's save hooks.
    def set_pinned(custom_field, pinned)
      return if custom_field.nil?

      if pinned
        record = find_or_initialize_by(custom_field_id: custom_field.id)
        record.position = (maximum(:position) || 0) + 1 if record.new_record?
        record.save!
      else
        where(custom_field_id: custom_field.id).delete_all
      end
    end

    # Drops pins whose custom field has since been deleted. Cheap, and keeps a deleted field from
    # lingering as a phantom tab if the record outlives its field.
    def purge_orphans!
      where.not(custom_field_id: CustomField.select(:id)).delete_all
    end
  end
end
