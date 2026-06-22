# frozen_string_literal: true

# Administration -> Titles
# Manages the master title list (reusing TaHiringTitle) and assigns one title per user.
class AdminTaTitlesController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :titles

  before_action :require_admin

  def index
    @titles = TaHiringTitle.active_ordered.to_a

    users_scope = User.active.where(type: 'User')
    @search = params[:q].to_s.strip
    users_scope = users_scope.like(@search) if @search.present?
    users_scope = users_scope.sorted

    @user_count = users_scope.count
    @user_pages = Paginator.new @user_count, per_page_option, params['page']
    @users = users_scope.offset(@user_pages.offset).limit(@user_pages.per_page).to_a

    # user_id => TaHiringTitle for the listed users (avoids N+1)
    @titles_by_user = TaUserTitle.where(user_id: @users.map(&:id))
                                 .includes(:title)
                                 .index_by(&:user_id)
  end

  # Assigns (or clears) a title for one or many users.
  # Params: title_id (blank = clear), user_id OR user_ids[]
  def assign
    user_ids = Array(params[:user_ids]).presence || Array(params[:user_id])
    user_ids = user_ids.map(&:to_i).reject(&:zero?).uniq
    title_id = params[:title_id].presence

    if user_ids.empty?
      flash[:error] = l(:notice_no_users_selected)
      return redirect_back_to_index
    end

    if title_id.blank?
      TaUserTitle.where(user_id: user_ids).destroy_all
      flash[:notice] = l(:notice_titles_cleared, count: user_ids.size)
    elsif TaHiringTitle.exists?(id: title_id)
      user_ids.each do |uid|
        record = TaUserTitle.find_or_initialize_by(user_id: uid)
        record.title_id = title_id
        record.save
      end
      flash[:notice] = l(:notice_titles_assigned, count: user_ids.size)
    else
      flash[:error] = l(:notice_title_not_found)
    end

    redirect_back_to_index
  end

  private

  def per_page_option
    50
  end

  def redirect_back_to_index
    redirect_to admin_ta_titles_path(q: params[:q].presence, page: params[:page].presence)
  end
end
