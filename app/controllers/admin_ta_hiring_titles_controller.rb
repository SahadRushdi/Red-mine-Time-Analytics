# frozen_string_literal: true

class AdminTaHiringTitlesController < ApplicationController
  before_action :require_admin
  before_action :find_hiring_title, only: [:destroy]

  def create
    title_value = params[:title].to_s.strip
    return render json: { error: 'Title is required.' }, status: :unprocessable_entity if title_value.blank?

    hiring_title = TaHiringTitle.find_by('LOWER(title) = ?', title_value.downcase)
    if hiring_title
      hiring_title.update!(active: true)
    else
      hiring_title = TaHiringTitle.create!(title: title_value, active: true)
    end

    render json: {
      title: serialize_title(hiring_title),
      titles: serialized_active_titles
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  def destroy
    @hiring_title.update!(active: false)
    render json: { titles: serialized_active_titles }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  private

  def find_hiring_title
    @hiring_title = TaHiringTitle.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Title not found.' }, status: :not_found
  end

  def serialized_active_titles
    TaHiringTitle.active.ordered_by_title.map { |title| serialize_title(title) }
  end

  def serialize_title(title)
    {
      id: title.id,
      title: title.title,
      destroy_url: admin_ta_hiring_title_path(title)
    }
  end
end
