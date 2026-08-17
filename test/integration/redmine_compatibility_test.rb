# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)
require 'digest'
require 'securerandom'

class RedmineTimeAnalyticsCompatibilityTest < ActionDispatch::IntegrationTest
  fixtures :projects

  test 'team settings routes use collection paths for index/create and a member path for destroy' do
    assert_routing(
      { path: '/admin/ta_team_settings', method: :get },
      { controller: 'admin_ta_team_settings', action: 'index' }
    )
    assert_routing(
      { path: '/admin/ta_team_settings', method: :post },
      { controller: 'admin_ta_team_settings', action: 'create' }
    )
    assert_routing(
      { path: '/admin/ta_team_settings/42', method: :delete },
      { controller: 'admin_ta_team_settings', action: 'destroy', id: '42' }
    )
  end

  test 'custom holiday named routes are declared once' do
    route_names = Rails.application.routes.routes.filter_map(&:name)
    show_route = Rails.application.routes.routes.any? do |route|
      route.defaults[:controller] == 'custom_holidays' && route.defaults[:action] == 'show'
    end

    assert_equal 1, route_names.count('custom_holidays')
    assert_equal 1, route_names.count('import_csv_custom_holidays')
    assert_not show_route
  end

  test 'in-process schedulers stay disabled in the test environment' do
    assert_nil RedmineTimeAnalytics::LeaveSyncScheduler.instance_variable_get(:@scheduler)
    assert_nil RedmineTimeAnalytics::MissingTimeScheduler.instance_variable_get(:@scheduler)
    assert_nil RedmineTimeAnalytics::ExternalTimeCacheScheduler.instance_variable_get(:@scheduler)
  end

  test 'team personal project URLs survive a database round trip as JSON' do
    project = Project.active.first
    assert project, 'An active project fixture is required for URL validation'

    project_url = "https://redmine.example.test/projects/#{project.identifier}"
    team = TaTeam.create!(
      name: "Compatibility team #{SecureRandom.hex(6)}",
      personal_project_urls: [project_url]
    )

    assert_equal [project_url], team.reload.personal_project_urls
  ensure
    team&.destroy!
  end

  test 'external time cache payload survives a database round trip as JSON' do
    cache = TaExternalTimeCache.create!(
      entry_key: Digest::SHA1.hexdigest(SecureRandom.hex(12)),
      project_identifier: 'compatibility-project',
      from_date: Date.new(2026, 8, 1),
      to_date: Date.new(2026, 8, 2),
      payload: [{ 'id' => 7, 'hours' => 1.5, 'metadata' => { 'source' => 'compatibility-test' } }]
    )

    assert_equal(
      [{ 'id' => 7, 'hours' => 1.5, 'metadata' => { 'source' => 'compatibility-test' } }],
      cache.reload.payload
    )
  ensure
    cache&.destroy!
  end
end
