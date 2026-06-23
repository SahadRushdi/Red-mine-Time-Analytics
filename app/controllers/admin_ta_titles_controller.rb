# frozen_string_literal: true

# Administration -> Titles
# Manages the master title list (reusing TaHiringTitle) and assigns one title per user.
# Active and locked users are loaded up-front and rendered/sorted/paginated client-side,
# mirroring the Leaves page UX (search + per-page + column sort + pagination).
class AdminTaTitlesController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :titles

  before_action :require_admin

  def index
    @titles = TaHiringTitle.active_ordered.to_a

    active_users = User.where(type: 'User', status: User::STATUS_ACTIVE).sorted.to_a
    locked_users = User.where(type: 'User', status: User::STATUS_LOCKED).sorted.to_a

    # user_id => title_id for every listed user (single query, avoids N+1)
    titles_by_user = TaUserTitle.where(user_id: (active_users + locked_users).map(&:id))
                                .pluck(:user_id, :title_id)
                                .to_h

    @active_users_data = serialize_users(active_users, titles_by_user)
    @locked_users_data = serialize_users(locked_users, titles_by_user)
    @active_count = active_users.size
    @locked_count = locked_users.size
  end

  # Assigns (or clears) a title for one or many users.
  # Params: title_id (blank = clear), user_id OR user_ids[].
  # Responds with JSON for XHR (the page updates in place) and falls back to a redirect.
  def assign
    user_ids = Array(params[:user_ids]).presence || Array(params[:user_id])
    user_ids = user_ids.map(&:to_i).reject(&:zero?).uniq
    title_id = params[:title_id].presence

    return respond_assign(error: l(:notice_no_users_selected)) if user_ids.empty?

    if title_id.blank?
      TaUserTitle.where(user_id: user_ids).destroy_all
      respond_assign(notice: l(:notice_titles_cleared, count: user_ids.size),
                     user_ids: user_ids, title_id: nil, title_name: nil)
    elsif (title = TaHiringTitle.find_by(id: title_id))
      user_ids.each do |uid|
        record = TaUserTitle.find_or_initialize_by(user_id: uid)
        record.title_id = title.id
        record.save
      end
      respond_assign(notice: l(:notice_titles_assigned, count: user_ids.size),
                     user_ids: user_ids, title_id: title.id, title_name: title.title)
    else
      respond_assign(error: l(:notice_title_not_found))
    end
  end

  private

  def serialize_users(users, titles_by_user)
    users.map do |user|
      {
        id: user.id,
        login: user.login.to_s,
        name: user.name.to_s,
        email: user.mail.to_s,
        title_id: titles_by_user[user.id]
      }
    end
  end

  def respond_assign(notice: nil, error: nil, user_ids: [], title_id: nil, title_name: nil)
    if request.xhr? || request.format.json?
      if error
        render json: { error: error }, status: :unprocessable_entity
      else
        render json: { ok: true, user_ids: user_ids, title_id: title_id,
                       title_name: title_name, notice: notice }
      end
    else
      flash[:error] = error if error
      flash[:notice] = notice if notice
      redirect_to admin_ta_titles_path
    end
  end
end
