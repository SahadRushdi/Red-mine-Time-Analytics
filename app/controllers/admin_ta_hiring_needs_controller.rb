class AdminTaHiringNeedsController < ApplicationController
  layout 'admin'
  menu_item :positions_hiring
  self.main_menu = false

  before_action :require_admin
  before_action :find_hiring_need, only: [:update, :destroy, :mark_filled, :mark_open]

  def index
    @all_teams = TaTeam.ordered_by_name.to_a
    @hiring_titles = TaHiringTitle.active_ordered.to_a
    @new_hiring_need = TaHiringNeed.new(priority: 'medium')
    @open_hiring_needs = TaHiringNeed.open.includes(:team).ordered_by_recent
    @filled_hiring_needs = TaHiringNeed.filled.includes(:team).ordered_by_recent
  end

  def create
    @hiring_need = TaHiringNeed.new(hiring_need_params.merge(status: 'open'))

    if @hiring_need.save
      flash[:notice] = l(:notice_successful_create)
    else
      flash[:error] = @hiring_need.errors.full_messages.join(', ')
    end

    redirect_back(fallback_location: admin_ta_hiring_needs_path)
  end

  def update
    if @hiring_need.update(hiring_need_params)
      flash[:notice] = l(:notice_successful_update)
    else
      flash[:error] = @hiring_need.errors.full_messages.join(', ')
    end

    redirect_back(fallback_location: admin_ta_hiring_needs_path)
  end

  def destroy
    if @hiring_need.destroy
      flash[:notice] = l(:notice_successful_delete)
    else
      flash[:error] = @hiring_need.errors.full_messages.presence&.join(', ') || 'Failed to delete hiring request.'
    end

    redirect_back(fallback_location: admin_ta_hiring_needs_path)
  end

  def mark_filled
    @hiring_need.mark_filled!
    flash[:notice] = l(:notice_successful_update)
  rescue ActiveRecord::RecordInvalid
    flash[:error] = @hiring_need.errors.full_messages.join(', ')
  ensure
    redirect_back(fallback_location: admin_ta_hiring_needs_path)
  end

  def mark_open
    @hiring_need.mark_open!
    flash[:notice] = l(:notice_successful_update)
  rescue ActiveRecord::RecordInvalid
    flash[:error] = @hiring_need.errors.full_messages.join(', ')
  ensure
    redirect_back(fallback_location: admin_ta_hiring_needs_path)
  end

  private

  def hiring_need_params
    params.require(:ta_hiring_need).permit(:title, :team_id, :priority)
  end

  def find_hiring_need
    @hiring_need = TaHiringNeed.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
