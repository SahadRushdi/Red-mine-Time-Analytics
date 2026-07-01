class AdminTaHiringTitlesController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin
  before_action :find_hiring_title, only: [:update, :destroy]

  def create
    @hiring_title = TaHiringTitle.new(title: title_params[:title].to_s.strip, active: true)

    if @hiring_title.save
      render json: {
        title: title_payload(@hiring_title),
        titles: titles_payload
      }, status: :created
    else
      render json: { error: @hiring_title.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    if @hiring_title.update(title: title_params[:title].to_s.strip)
      render json: {
        title: title_payload(@hiring_title),
        titles: titles_payload
      }, status: :ok
    else
      render json: { error: @hiring_title.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def destroy
    if @hiring_title.destroy
      render json: { titles: titles_payload }, status: :ok
    else
      render json: { error: @hiring_title.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  private

  def title_params
    params.permit(:title)
  end

  def find_hiring_title
    @hiring_title = TaHiringTitle.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def title_payload(hiring_title)
    {
      id: hiring_title.id,
      title: hiring_title.title,
      destroy_url: admin_ta_hiring_title_path(hiring_title)
    }
  end

  def titles_payload
    TaHiringTitle.active_ordered.map { |hiring_title| title_payload(hiring_title) }
  end
end
