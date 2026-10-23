# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)

class IndividualDashboardChartsTest < Redmine::IntegrationTest
  setup do
    @entries = TimeEntry.joins(:project).where(projects: { status: Project::STATUS_ACTIVE })
                        .where.not(issue_id: nil).order(:id).to_a.uniq(&:issue_id).first(2)
    @entries.each_with_index do |entry, index|
      entry.update_columns(hours: [2.5, 3.25][index], spent_on: Date.current, user_id: 2)
      entry.project.enabled_modules.find_or_create_by!(name: 'issue_tracking')
    end
    log_user('admin', 'admin')
  end

  test 'built-in individual tabs produce populated stacked charts for every time grouping' do
    cases = []
    %w[issue activity project].each do |view_mode|
      %w[daily weekly monthly].each do |grouping|
        get '/my/time', params: { user_id: 2, filter: 'custom', from: (Date.current - 1).to_s,
                                 to: Date.current.to_s, view_mode: view_mode, grouping: grouping, chart_type: 'bar' }
        assert_response :success
        element = css_select('#time-chart').first
        chart = JSON.parse(element['data-chart'])
        cases << { name: "#{view_mode}-#{grouping}", chart: chart, html: response.body }
        assert_equal 'bar', chart['type']
        assert_not_empty chart['data']['datasets']
        chart['data']['datasets'].each do |dataset|
          assert dataset['data'].all? { |value| value.is_a?(Numeric) }, 'hours must be JSON numbers, not Rational strings'
        end
        assert_in_delta 5.75, chart['data']['datasets'].sum { |dataset| dataset['data'].compact.sum }, 0.001,
                        "#{view_mode}/#{grouping} must include all logged hours"
        assert chart['options']['scales']['xAxes'].first['stacked']
        assert chart['options']['scales']['yAxes'].first['stacked']
      end
    end
  ensure
    File.write(ENV['TA_CHART_CASES'], JSON.generate(cases)) if ENV['TA_CHART_CASES']
  end

  test 'empty ranges on built-in tabs return an empty stacked chart without errors' do
    %w[issue activity project].each do |view_mode|
      get '/my/time', params: { user_id: 2, filter: 'custom', from: '2040-01-01', to: '2040-01-02',
                               view_mode: view_mode, grouping: 'daily', chart_type: 'bar' }
      assert_response :success
      chart = JSON.parse(css_select('#time-chart').first['data-chart'])
      assert_equal 'bar', chart['type']
      assert_empty chart['data']['datasets']
    end
  end
end
