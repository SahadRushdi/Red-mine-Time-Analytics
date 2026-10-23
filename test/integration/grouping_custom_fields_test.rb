# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)

class GroupingCustomFieldsTest < Redmine::ControllerTest
  tests CustomFieldsController

  def setup
    @request.session[:user_id] = 1
  end

  test 'create and update persist eligible grouping pins on both field types' do
    %w[IssueCustomField TimeEntryCustomField].each_with_index do |type, index|
      post :create, params: { type: type, ta_pinned_grouping: '1',
                             custom_field: { name: "TA Customer #{index}", field_format: 'string', is_filter: '1' } }
      assert_response :redirect
      cf = CustomField.find_by!(name: "TA Customer #{index}")
      assert TaPinnedGrouping.pinned?(cf)
      assert_includes RedmineTimeAnalytics::GroupableFieldRegistry.pinned.map { |field| field.custom_field.id }, cf.id

      put :update, params: { id: cf.id, ta_pinned_grouping: '0', custom_field: { is_filter: '1' } }
      assert_response :redirect
      assert_not TaPinnedGrouping.pinned?(cf)
    end
  end

  test 'ineligible saves cannot create pins and preserve existing pin intent' do
    post :create, params: { type: 'IssueCustomField', ta_pinned_grouping: '1',
                           custom_field: { name: 'TA Ineligible', field_format: 'string', is_filter: '0' } }
    cf = CustomField.find_by!(name: 'TA Ineligible')
    assert_not TaPinnedGrouping.pinned?(cf)

    cf.update!(is_filter: true)
    TaPinnedGrouping.set_pinned(cf, true)
    put :update, params: { id: cf.id, ta_pinned_grouping: '0', custom_field: { is_filter: '0' } }
    assert_response :redirect
    assert TaPinnedGrouping.pinned?(cf.reload)
    assert_not_includes RedmineTimeAnalytics::GroupableFieldRegistry.pinned.map { |field| field.custom_field.id }, cf.id
  end

  test 'grouping checkbox explains filter prerequisite and remains disabled until eligible' do
    get :new, params: { type: 'IssueCustomField', custom_field: { field_format: 'string' } }
    assert_response :success
    assert_select '#ta_pinned_grouping[disabled]', 1
    assert_select '#ta-pinned-grouping-control em', text: /Used as a filter/

    get :new, params: { type: 'IssueCustomField', custom_field: { field_format: 'string', is_filter: '1' } }
    assert_select '#ta_pinned_grouping:not([disabled])', 1
  end

  test 'AJAX format refresh includes supported grouping controls and hides unsupported controls' do
    %w[bool int float enumeration text].each do |format|
      get :new, params: { type: 'IssueCustomField', custom_field: { field_format: format } }
      assert_response :success
      assert_select '#ta-pinned-grouping-control[hidden]', format == 'text' ? 1 : 0
    end

    get :new, params: { type: 'IssueCustomField', custom_field: { field_format: 'list', multiple: '1' } }, xhr: true
    assert_response :success
    assert_includes @response.body, 'ta-pinned-grouping-control'
  end
end

class GroupingDashboardsTest < Redmine::IntegrationTest
  test 'both picker endpoints discover new fields and pin changes without cached responses' do
    log_user('admin', 'admin')
    %w[/my/time/groupable_fields /team/analytics/groupable_fields].each_with_index do |path, index|
      get path
      assert_response :success
      assert_includes response.headers['Cache-Control'], 'no-store'
      cf = IssueCustomField.create!(name: "TA Fresh #{index}", field_format: 'bool', is_filter: true)
      key = "cf_issue_#{cf.id}"
      get path
      fields = JSON.parse(response.body).fetch('sections').flat_map { |section| section.fetch('fields') }
      assert_equal false, fields.find { |field| field['key'] == key }.fetch('pinned')
      TaPinnedGrouping.set_pinned(cf, true)
      get path
      fields = JSON.parse(response.body).fetch('sections').flat_map { |section| section.fetch('fields') }
      assert_equal true, fields.find { |field| field['key'] == key }.fetch('pinned')
      cf.update!(is_filter: false)
      get path
      assert_not_includes JSON.parse(response.body).fetch('sections').flat_map { |s| s['fields'].map { |f| f['key'] } }, key
    end
  end

  test 'Customer pin renders by default and opens grouped results on both dashboards' do
    log_user('admin', 'admin')
    entry = TimeEntry.joins(:project).where(projects: { status: Project::STATUS_ACTIVE }).where.not(issue_id: nil).first
    entry.project.enabled_modules.find_or_create_by!(name: 'issue_tracking')
    cf = IssueCustomField.create!(name: 'TA Customer Dashboard', field_format: 'string', is_filter: true,
                                  is_for_all: true, trackers: [entry.issue.tracker])
    CustomValue.create!(customized: entry.issue, custom_field: cf, value: 'Acme')
    TaPinnedGrouping.set_pinned(cf, true)
    key = "cf_issue_#{cf.id}"
    team = TaTeam.create!(name: 'TA Group Dashboard')
    TaTeamSetting.create!(user_id: 1, setting_type: 'super_user')
    TaTeamMembership.create!(team: team, user: entry.user, role: 'member', start_date: entry.spent_on)
    TaTeamProject.create!(team: team, project: entry.project, source_type: 'local', start_date: entry.spent_on)
    date_params = { filter: 'custom', from: entry.spent_on.to_s, to: entry.spent_on.to_s }

    { '/my/time' => { user_id: entry.user_id }, '/team/analytics' => { team_id: team.id } }.each do |path, extra|
      get path, params: date_params.merge(extra)
      assert_response :success
      assert_select "#ta-grouping-navigation a[href*='view_mode=#{key}']", text: /TA Customer Dashboard/, count: 1
      %w[daily weekly monthly].each do |grouping|
        get path, params: date_params.merge(extra).merge(view_mode: key, grouping: grouping)
        assert_response :success
        assert_select '#ta-grouping-navigation .ta-view-tab-active', text: /TA Customer Dashboard/, count: 1
        assert_select '#view-mode-table h3', text: /Time by TA Customer Dashboard/
        assert response.body.include?('Acme'), "#{path} #{grouping} must group the visible Customer value"
      end
    end
  end
end
