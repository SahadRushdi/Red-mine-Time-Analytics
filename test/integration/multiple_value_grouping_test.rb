# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)

module MultipleValueGroupingData
  def prepare_entries
    User.current = User.find(1)
    @entries = TimeEntry.joins(:project).where(projects: { status: Project::STATUS_ACTIVE })
                        .where.not(issue_id: nil).order(:id).to_a.uniq(&:issue_id).first(2)
    @entries.each do |entry|
      entry.update_columns(hours: 8, user_id: 2, spent_on: Date.current)
      entry.project.enabled_modules.find_or_create_by!(name: 'issue_tracking')
    end
  end

  def make_field(klass = IssueCustomField, format = 'list')
    attrs = { name: "Customers #{klass.name == 'IssueCustomField' ? 'Issue' : 'Time'} #{format}",
              field_format: format, is_filter: true, multiple: true }
    attrs[:possible_values] = %w[A B] if format == 'list'
    attrs.merge!(is_for_all: true, trackers: Tracker.all) if klass == IssueCustomField
    cf = klass.create!(attrs)
    values = case format
             when 'enumeration' then %w[A B].map { |name| cf.enumerations.create!(name: name).id.to_s }
             when 'user' then User.where(id: [2, 3]).order(:id).pluck(:id).map(&:to_s)
             when 'version' then %w[A B].map { |name| Version.create!(project: @entries.first.project, name: "#{cf.id} #{name}").id.to_s }
             else %w[A B]
             end
    @entries.each_with_index do |entry, index|
      record = klass == IssueCustomField ? entry.issue : entry
      (index.zero? ? values : values.first(1)).each do |value|
        CustomValue.insert_all!([{ customized_type: record.class.base_class.name,
                                   customized_id: record.id, custom_field_id: cf.id, value: value }])
      end
    end
    [cf, values]
  end

  def field_for(cf)
    prefix = cf.is_a?(IssueCustomField) ? 'cf_issue' : 'cf_te'
    RedmineTimeAnalytics::GroupableFieldRegistry.find("#{prefix}_#{cf.id}")
  end

  def entry_scope
    TimeEntry.joins(:project).where(projects: { status: Project::STATUS_ACTIVE }, id: @entries.map(&:id))
  end

  def make_pivot(field)
    RedmineTimeAnalytics::DimensionPivot.build(
      scope: entry_scope, field: field, grouping: 'daily',
      period_totals_fn: ->(s, _) { s.group(:spent_on).sum(:hours) },
      category_totals_fn: lambda { |s, _, col|
        s.group(:spent_on, col).sum(:hours).each_with_object({}) do |((date, value), hours), result|
          (result[date] ||= {})[value] = hours
        end
      }, period_display_fn: ->(date) { date.to_s }, none_label: '(none)'
    )
  end
end

class MultipleValueGroupingTest < ActiveSupport::TestCase
  include MultipleValueGroupingData
  Registry = RedmineTimeAnalytics::GroupableFieldRegistry
  Pivot = RedmineTimeAnalytics::DimensionPivot

  setup { prepare_entries }
  teardown { User.current = nil }

  test 'all native multiple-value formats group each selection once on issues and time entries' do
    [IssueCustomField, TimeEntryCustomField].each do |klass|
      %w[list enumeration user version].each do |format|
        cf, values = make_field(klass, format)
        field = field_for(cf)
        assert_not_nil field
        assert field.multiple?
        TaPinnedGrouping.set_pinned(cf, true)
        assert_includes Registry.pinned.map(&:key), field.key
        assert_includes Registry.picker_payload.flat_map { |s| s[:fields].map { |f| f[:key] } }, field.key
        pivot = make_pivot(field)
        names = field.resolver.call(values)
        assert_equal 24, pivot[:grand_total]
        assert_equal 16, pivot[:logged_total]
        assert_equal 'per_value', pivot[:counting_mode]
        assert_equal 24, pivot[:period_totals][Date.current]
        assert_equal 16, pivot[:category_totals][names[values[0]]]
        assert_equal 8, pivot[:category_totals][names[values[1]]]
        assert_equal 24, pivot[:matrix][Date.current].values.sum
        assert_equal 16, Pivot.scope_for_value(entry_scope, field, values[0]).sum(:hours)
        assert_equal [@entries.first.id], Pivot.scope_for_value(entry_scope, field, values[1]).pluck(:id)
      end
    end
  end

  test 'duplicate copies of one selection and empty rows do not add hours' do
    cf, = make_field
    %w[A A].push('').each do |value|
      CustomValue.insert_all!([{ customized_type: 'Issue', customized_id: @entries.first.issue_id,
                                 custom_field_id: cf.id, value: value }])
    end
    pivot = make_pivot(field_for(cf))
    assert_equal({ 'A' => 16.0, 'B' => 8.0 }, pivot[:category_totals])
    assert_equal 24, pivot[:grand_total]
  end

  test 'missing issue or missing selections contributes once to no value' do
    cf, = make_field
    @entries.last.update_columns(issue_id: nil)
    field = field_for(cf)
    pivot = make_pivot(field)
    assert_equal 24, pivot[:grand_total]
    assert_equal 8, pivot[:category_totals]['(none)']
    assert_equal [@entries.last.id], Pivot.scope_for_value(entry_scope, field, nil).pluck(:id)
    CustomValue.where(custom_field_id: cf.id).delete_all
    assert_equal({ '(none)' => 16.0 }, make_pivot(field)[:category_totals])
  end

  test 'time-entry selections differ independently even on the same issue' do
    cf, = make_field(TimeEntryCustomField)
    @entries.last.update_columns(issue_id: @entries.first.issue_id)
    pivot = make_pivot(field_for(cf))
    assert_equal({ 'A' => 16.0, 'B' => 8.0 }, pivot[:category_totals])
    assert_equal 24, pivot[:grand_total]
  end

  test 'project and tracker applicability still hide inapplicable selected values' do
    cf, = make_field
    cf.update!(is_for_all: false, project_ids: [])
    assert_equal({ '(none)' => 16.0 }, make_pivot(field_for(cf))[:category_totals])
    cf.update!(is_for_all: true, tracker_ids: [])
    assert_equal({ '(none)' => 16.0 }, make_pivot(field_for(cf))[:category_totals])
  end

  test 'distinct users with identical names remain separate groups' do
    User.where(id: [2, 3]).update_all(firstname: 'Same', lastname: 'Person')
    cf, values = make_field(IssueCustomField, 'user')
    pivot = make_pivot(field_for(cf))
    assert_equal 2, pivot[:categories].size
    assert_equal values.sort, pivot[:category_values].values.sort
    assert_equal [8.0, 16.0], pivot[:category_totals].values.sort
  end

  test 'version names matching generated labels keep their own totals and drill downs' do
    [IssueCustomField, TimeEntryCustomField].each do |klass|
      cf, values = make_field(klass, 'version')
      first, second = Version.find(values)
      projects = %w[a b].map do |suffix|
        Project.create!(name: "Label collision #{cf.id} #{suffix}", identifier: "ta-label-#{cf.id}-#{suffix}")
      end
      first.update!(project: projects[0], name: 'Release', sharing: 'system')
      second.update!(project: projects[1], name: 'Release', sharing: 'system')
      third = Version.create!(project: projects[0], name: "Release (#{first.id})", sharing: 'system')
      record = klass == IssueCustomField ? @entries.first.issue : @entries.first
      CustomValue.insert_all!([{ customized_type: record.class.base_class.name,
                                 customized_id: record.id, custom_field_id: cf.id, value: third.id.to_s }])
      field = field_for(cf)
      pivot = make_pivot(field)
      assert_equal 3, pivot[:categories].size, 'all three versions must remain separate'
      assert_equal (values + [third.id.to_s]).sort, pivot[:category_values].values.sort
      assert_equal 32, pivot[:grand_total]
      assert_equal 32, pivot[:category_totals].values.sum
      assert_equal 32, pivot[:matrix][Date.current].values.sum
      assert_equal 8, pivot[:category_totals][third.name], 'retain the existing unique version name'
      pivot[:category_values].each do |name, raw|
        hours = Pivot.scope_for_value(entry_scope, field, raw).sum(:hours).to_f
        assert_equal pivot[:category_totals][name], hours, "#{name} must reconcile when expanded"
      end
    end
  end

  test 'disambiguation avoids reserved names and repeated suffixes regardless of input order' do
    names = { '1' => 'Release', '2' => 'Release', '3' => 'Release (1)',
              '4' => 'Release (1) [2]', '5' => 'Release (1) [3]',
              '6' => '(none)', '7' => '(none) (6)' }
    field = Registry::Field.new(custom_field: TimeEntryCustomField.new(field_format: 'list', multiple: true),
                                resolver: ->(_) { names })
    labels = Pivot.label_map(field, names.keys, '(none)')
    assert_equal labels.size, labels.values.uniq.size
    assert_equal '(none)', labels[Pivot::NONE_KEY]
    %w[3 4 5 7].each { |raw| assert_equal names[raw], labels[raw], 'unique existing names must be preserved' }
    assert_equal labels, Pivot.label_map(field, names.keys.reverse, '(none)')
  end
end

class MultipleValueGroupingDashboardsTest < Redmine::IntegrationTest
  include MultipleValueGroupingData

  setup do
    prepare_entries
    # Restrict each request's date/user scope to our two 8h entries.
    @entries.each { |entry| entry.update_columns(user_id: 2) }
    @team = TaTeam.create!(name: 'Multiple value team')
    TaTeamSetting.create!(user_id: 1, setting_type: 'super_user')
    TaTeamMembership.create!(team: @team, user_id: 2, role: 'member', start_date: Date.current)
    @entries.map(&:project).uniq.each do |project|
      TaTeamProject.create!(team: @team, project: project, source_type: 'local', start_date: Date.current)
    end
    log_user('admin', 'admin')
  end

  teardown { User.current = nil }

  def dashboard_params(field)
    { filter: 'custom', from: Date.current.to_s, to: Date.current.to_s,
      view_mode: field.key, grouping: 'daily', user_id: 2, team_id: @team.id }
  end

  test 'both dashboards show 24 grouped hours and explain 16 across the first issues customers' do
    cf, = make_field
    field = field_for(cf)
    TaPinnedGrouping.set_pinned(cf, true)
    %w[/my/time /team/analytics].each do |path|
      %w[daily weekly monthly].each do |period|
        get path, params: dashboard_params(field).merge(grouping: period)
        assert_response :success
        assert_select '.ts-summary-card--total .ts-summary-card-value', text: /24:00/
        assert_select '.ts-summary-card--total', text: /Hours across Customers Issue list/
        assert_select '.ts-summary-card--total', text: /16:00 hours actually logged/
        payload = JSON.parse(css_select('[id$="-payload"][data-payload]').first['data-payload'])
        assert_equal 24, payload['grandTotal']
        assert_equal 16, payload['loggedTotal']
        assert_equal 'per_value', payload['countingMode']
        assert_equal({ 'A' => 16.0, 'B' => 8.0 }, payload['items'].to_h { |item| [item['name'], item['hours']] })
        chart = JSON.parse(css_select('canvas[data-chart]').first['data-chart'])
        assert_in_delta 24, chart['data']['datasets'].sum { |dataset| dataset['data'].compact.sum }, 0.001
        assert_select '.time-overview-box tbody', text: /24:00/ if path == '/my/time'
        if period == 'daily'
          if path == '/my/time'
            assert_select '.ts-summary-card--average .ts-summary-card-value', text: /24:00/
            assert_select '.ts-summary-card--issues .ts-summary-card-value', text: /2/
          else
            assert_select '.ts-summary-card--average .ts-summary-card-value', text: /24:00/
            assert_select '.ts-summary-card--issues .ts-summary-card-value', text: /24:00/
          end
        end
      end
      get "#{path}/group_breakdown", params: dashboard_params(field).merge(group_by: field.key, group_value: 'A')
      assert_response :success
      response_data = JSON.parse(response.body)
      assert_equal 16, response_data['grandTotal']
      first = response_data['items'].find { |item| item['id'] == @entries.first.issue_id }
      assert_equal 8, first['hours']
      assert_equal 8, first['loggedHours']
      assert_equal 16, first['groupedHours']
      assert_equal({ 'A' => 8.0, 'B' => 8.0 }, first['valueBreakdown'].to_h { |row| [row['name'], row['hours']] })
      export_path = path == '/my/time' ? '/time_analytics/export_csv' : '/team/analytics/export_csv'
      post export_path, params: dashboard_params(field)
      assert_response :success
      assert_includes response.body, '24:00'
      assert_includes response.body, 'Actual logged hours,16:00'
    end
  end

  test 'time-entry explanations combine each entries selections and include no issue rows' do
    cf, = make_field(TimeEntryCustomField)
    @entries.last.update_columns(issue_id: @entries.first.issue_id)
    field = field_for(cf)
    %w[/my/time /team/analytics].each do |path|
      get "#{path}/group_breakdown", params: dashboard_params(field).merge(group_by: field.key, group_value: 'A')
      item = JSON.parse(response.body)['items'].first
      assert_equal 16, item['hours']
      assert_equal 16, item['loggedHours']
      assert_equal 24, item['groupedHours']
    end
    @entries.last.update_columns(issue_id: nil)
    get '/my/time/group_breakdown', params: dashboard_params(field).merge(group_by: field.key, group_value: 'A')
    data = JSON.parse(response.body)
    assert_equal 16, data['grandTotal']
    row = data['items'].find { |item| item['id'].nil? }
    assert_nil row['url']
    assert_equal 8, row['hours']
  end

  test 'grouping explanations exclude hours outside the dashboards date scope' do
    cf, = make_field
    extra = @entries.first.dup
    extra.spent_on = Date.yesterday
    extra.hours = 40
    extra.save!
    field = field_for(cf)
    %w[/my/time /team/analytics].each do |path|
      get "#{path}/group_breakdown", params: dashboard_params(field).merge(group_by: field.key, group_value: 'A')
      assert_response :success
      first = JSON.parse(response.body)['items'].find { |item| item['id'] == @entries.first.issue_id }
      assert_equal 8, first['loggedHours']
      assert_equal 16, first['groupedHours']
    end
  end
end
