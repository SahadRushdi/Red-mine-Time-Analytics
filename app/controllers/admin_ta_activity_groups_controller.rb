# frozen_string_literal: true

# Administration -> Activity Groups
# Lets an admin define named groups (e.g. "Effective dev effort", "Customer support") and map
# each Redmine time-logging Activity to exactly one group. This is the default grouping shown on
# the Team Dashboard's "Grouped" activity tab. Activities with no assignment row fall back to a
# computed "Ungrouped" bucket at read time (never persisted).
class AdminTaActivityGroupsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :activity_groups

  before_action :require_admin
  before_action :find_group, only: [:update, :destroy]

  def index
    @groups = TaActivityGroup.ordered.to_a
    @activities = TimeEntryActivity.shared.sorted.to_a
    @assignments = TaActivityGroupAssignment.pluck(:activity_id, :group_id).to_h
  end

  def create
    @group = TaActivityGroup.new(group_params)

    if @group.save
      respond_ok(notice: l(:notice_successful_create), group: @group)
    else
      respond_error(@group.errors.full_messages.join(', '))
    end
  end

  def update
    if @group.update(group_params)
      respond_ok(notice: l(:notice_successful_update), group: @group)
    else
      respond_error(@group.errors.full_messages.join(', '))
    end
  end

  def destroy
    group_id = @group.id
    @group.destroy
    respond_ok(notice: l(:notice_successful_delete), group_id: group_id)
  end

  # Assigns (or clears) a group for one activity.
  # Params: activity_id (required), group_id (blank = ungroup).
  def assign
    activity_id = params[:activity_id].presence&.to_i

    return respond_error(l(:notice_no_activity_selected)) if activity_id.blank?

    group_id = params[:group_id].presence

    if group_id.blank?
      TaActivityGroupAssignment.where(activity_id: activity_id).destroy_all
      respond_ok(notice: l(:notice_successful_update), activity_id: activity_id, group_id: nil)
    else
      assignment = TaActivityGroupAssignment.find_or_initialize_by(activity_id: activity_id)
      assignment.group_id = group_id

      if assignment.save
        respond_ok(notice: l(:notice_successful_update), activity_id: activity_id, group_id: assignment.group_id)
      else
        respond_error(assignment.errors.full_messages.join(', '))
      end
    end
  end

  # Bulk-reorders groups. Params: ids[] (group ids in the desired display order).
  def reorder
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)

    TaActivityGroup.transaction do
      ids.each_with_index do |id, index|
        TaActivityGroup.where(id: id).update_all(position: index)
      end
    end

    respond_ok(notice: l(:notice_successful_update), groups: TaActivityGroup.ordered.to_a)
  end

  private

  def find_group
    @group = TaActivityGroup.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def group_params
    params.require(:ta_activity_group).permit(:name)
  end

  def respond_ok(notice: nil, **extra)
    if request.xhr? || request.format.json?
      render json: { ok: true, notice: notice }.merge(serialize_extra(extra))
    else
      flash[:notice] = notice
      redirect_to admin_ta_activity_groups_path
    end
  end

  def respond_error(error)
    if request.xhr? || request.format.json?
      render json: { ok: false, error: error }, status: :unprocessable_entity
    else
      flash[:error] = error
      redirect_to admin_ta_activity_groups_path
    end
  end

  def serialize_extra(extra)
    ordered_ids = TaActivityGroup.ordered.pluck(:id)
    colors = TaActivityGroup.tableau10_colors(ordered_ids.size)
    group_json = lambda do |g|
      { id: g.id, name: g.name, position: g.position, color: colors[ordered_ids.index(g.id) || 0] }
    end

    extra.transform_values do |value|
      case value
      when TaActivityGroup
        group_json.call(value)
      when Array
        value.map { |g| g.is_a?(TaActivityGroup) ? group_json.call(g) : g }
      else
        value
      end
    end
  end
end
