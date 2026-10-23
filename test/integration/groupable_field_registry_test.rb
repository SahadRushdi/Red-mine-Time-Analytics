# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)

# Covers the generic "group by" tabs: which fields the registry exposes, that the grouped SQL can
# never inflate SUM(hours) through its joins, and that the no-value bucket collapses correctly.
class GroupableFieldRegistryTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles,
           :trackers, :issue_statuses, :enumerations, :issues,
           :time_entries, :custom_fields, :custom_values, :custom_fields_trackers

  Registry = RedmineTimeAnalytics::GroupableFieldRegistry
  Pivot    = RedmineTimeAnalytics::DimensionPivot

  def setup
    User.current = User.find(1) # admin

    # TimeEntry.left_join_issue carries Issue.visible_condition, which requires the issue_tracking
    # module on the *time entry's* project. Without it every issue-derived dimension silently
    # resolves to the no-value bucket and these assertions would pass vacuously.
    Project.where(status: Project::STATUS_ACTIVE).find_each do |project|
      project.enabled_modules.find_or_create_by!(name: 'issue_tracking')
    end
  end

  def teardown
    User.current = nil
  end

  def scope
    TimeEntry.joins(:project).where(projects: { status: Project::STATUS_ACTIVE })
  end

  # Mirrors the controllers' daily bucketers, which is all these assertions need.
  def period_fn
    ->(s, _g) { s.reorder(nil).group(:spent_on).sum(:hours) }
  end

  def category_fn
    lambda do |s, _g, column|
      s.reorder(nil).group(:spent_on, column).sum(:hours)
       .each_with_object({}) { |((date, value), hours), acc| (acc[date] ||= {})[value] = hours }
    end
  end

  def build(field)
    Pivot.build(scope: scope, field: field, grouping: 'daily',
                period_totals_fn: period_fn, category_totals_fn: category_fn,
                period_display_fn: ->(key) { key.to_s }, none_label: '(none)')
  end

  test 'static issue dimensions are always available' do
    keys = Registry.all(User.current).map(&:key)

    %w[issue_tracker issue_status issue_priority issue_category
       issue_fixed_version issue_author issue_assigned_to].each do |key|
      assert_includes keys, key
    end
  end

  test 'pinned tab view_modes are never treated as dimensions' do
    %w[issue activity project members time_entries].each do |key|
      assert_not Registry.dimension?(key), "#{key} must stay a pinned tab"
      assert_nil Registry.find(key, User.current)
    end
  end

  test 'unknown and malformed keys resolve to nil rather than raising' do
    ['cf_issue_999999', 'cf_te_999999', '../../etc/passwd', 'nope', ''].each do |key|
      assert_nil Registry.find(key, User.current)
    end
  end

  test 'only supported groupable formats are exposed' do
    Registry.all(User.current).filter_map(&:custom_field).each do |cf|
      assert Registry.supported?(cf)
      assert_includes Registry::GROUPABLE_CF_FORMATS, cf.field_format
    end
  end

  test 'every supported format is discovered dynamically on issues and time entries' do
    [IssueCustomField, TimeEntryCustomField].each do |klass|
      Registry::GROUPABLE_CF_FORMATS.each do |format|
        attributes = { name: "TA #{klass == IssueCustomField ? 'Issue' : 'Time'} #{format}", field_format: format, is_filter: true }
        attributes[:possible_values] = %w[Acme Globex] if format == 'list'
        cf = klass.create!(attributes)
        key = "#{klass == IssueCustomField ? 'cf_issue' : 'cf_te'}_#{cf.id}"
        field = Registry.find(key, User.current)
        assert_not_nil field, "#{klass.name} #{format} must appear immediately"
        assert_nothing_raised { build(field) }
        assert_includes Registry.picker_payload(User.current).flat_map { |s| s[:fields].map { |f| f[:key] } }, key
      end
    end
  end

  test 'hidden fields cannot be selected or pinned for an unauthorized viewer' do
    cf = IssueCustomField.create!(name: 'TA Private', field_format: 'string', is_filter: true,
                                  visible: false, roles: [Role.find(1)])
    TaPinnedGrouping.set_pinned(cf, true)
    viewer = User.anonymous

    assert_nil Registry.find("cf_issue_#{cf.id}", viewer)
    assert_not_includes Registry.pinned(viewer).map { |f| f.custom_field.id }, cf.id
  end

  test 'Boolean and enumeration groups display human readable labels' do
    cf = IssueCustomField.create!(name: 'TA Boolean', field_format: 'bool', is_filter: true)
    field = Registry.find("cf_issue_#{cf.id}")
    assert_equal I18n.t(:general_text_No), field.resolver.call(['0'])['0']
    assert_equal I18n.t(:general_text_Yes), field.resolver.call(['1'])['1']

    cf = IssueCustomField.create!(name: 'TA Key Value', field_format: 'enumeration', is_filter: true)
    choice = cf.enumerations.create!(name: 'Customer Acme')
    assert_equal 'Customer Acme', Registry.find("cf_issue_#{cf.id}").resolver.call([choice.id.to_s])[choice.id.to_s]
  end

  test 'numeric groups partition hours including zero and missing values' do
    %w[int float progressbar].each do |format|
      cf = TimeEntryCustomField.create!(name: "TA Numeric #{format}", field_format: format, is_filter: true)
      entries = scope.limit(3).to_a
      assert_equal 3, entries.length
      CustomValue.create!(customized: entries[0], custom_field: cf, value: '0')
      CustomValue.create!(customized: entries[1], custom_field: cf, value: format == 'float' ? '1.25' : '25')
      CustomValue.create!(customized: entries[2], custom_field: cf, value: '')
      field = Registry.find("cf_te_#{cf.id}")
      pivot = build(field)
      assert_includes pivot[:categories], '0'
      assert_includes pivot[:categories], '(none)'
      total = pivot[:category_values].values.sum do |value|
        Pivot.scope_for_value(scope, field, value).sum(:hours).to_f
      end
      assert_in_delta scope.sum(:hours).to_f, total, 0.001
      assert_no_match(/= ''/, Pivot.scope_for_value(scope, field, nil).where_clause.ast.to_sql)
    end
  end

  test 'float grouping and drill downs preserve the stored decimal precision' do
    entries = scope.where.not(issue_id: nil).order(:id).to_a.uniq(&:issue_id).first(2)
    assert_equal 2, entries.length

    [IssueCustomField, TimeEntryCustomField].each do |klass|
      [
        %w[1.0001 1.0002],
        %w[1.0000000000000001 1.0000000000000002],
        %w[-0.0001 -0.0002],
        %w[0.00000000000000000001 0.00000000000000000002],
        %w[1.0 1.00]
      ].each_with_index do |values, index|
        issue_field = klass == IssueCustomField
        attributes = { name: "TA Float #{issue_field ? 'Issue' : 'Time'} #{index}", field_format: 'float', is_filter: true }
        attributes.merge!(is_for_all: true, trackers: entries.map { |entry| entry.issue.tracker }.uniq) if issue_field
        cf = klass.create!(attributes)
        entries.zip(values).each do |entry, value|
          CustomValue.create!(customized: issue_field ? entry.issue : entry, custom_field: cf, value: value)
        end

        field = Registry.find("#{issue_field ? 'cf_issue' : 'cf_te'}_#{cf.id}")
        pivot = build(field)
        entries.zip(values).each do |entry, value|
          assert_includes pivot[:categories], value
          assert_equal value, pivot[:category_values][value], 'group identity must retain every stored digit'
          expected = scope.where(issue_field ? { issue_id: entry.issue_id } : { id: entry.id })
          actual = Pivot.scope_for_value(scope, field, pivot[:category_values][value])
          assert_equal expected.order(:id).pluck(:id), actual.order(:id).pluck(:id),
                       "drill down for #{value} must include only that group"
          assert_in_delta expected.sum(:hours).to_f, pivot[:category_totals][value], 0.001
        end
        assert_in_delta scope.sum(:hours).to_f, pivot[:category_totals].values.sum, 0.001
      end
    end
  end

  test 'custom fields not used as a filter are excluded' do
    cf = IssueCustomField.create!(name: 'TA Not A Filter', field_format: 'list',
                                  possible_values: %w[a b], is_filter: false, is_for_all: true)

    assert_nil Registry.find("cf_issue_#{cf.id}", User.current)

    cf.update!(is_filter: true)
    assert_not_nil Registry.find("cf_issue_#{cf.id}", User.current),
                   'ticking "Used as a filter" should make it groupable with no code change'
  end

  test 'long text is excluded while supported multi-value fields are exposed' do
    text = IssueCustomField.create!(name: 'TA Long Text', field_format: 'text',
                                    is_filter: true, is_for_all: true)
    multi = IssueCustomField.create!(name: 'TA Multi', field_format: 'list', multiple: true,
                                     possible_values: %w[a b], is_filter: true, is_for_all: true)

    assert_nil Registry.find("cf_issue_#{text.id}", User.current)
    assert_not_nil Registry.find("cf_issue_#{multi.id}", User.current)
  end

  # Redmine's CustomField#group_statement returns nil for `string`; the registry falls back to
  # #order_statement so these fields stay groupable without patching core.
  test 'string format custom fields are groupable via the order_statement fallback' do
    cf = IssueCustomField.create!(name: 'TA Customer', field_format: 'string',
                                  is_filter: true, is_for_all: true)

    assert_nil cf.group_statement, 'precondition: core cannot group a string field'
    field = Registry.find("cf_issue_#{cf.id}", User.current)
    assert_not_nil field
    assert field.group_sql.to_s.present?
    assert_nothing_raised { build(field) }
  end

  test 'grouping never inflates total hours, for every registered dimension' do
    baseline = scope.reorder(nil).sum(:hours).to_f
    assert baseline.positive?, 'fixtures must contain time entries for this to mean anything'

    Registry.all(User.current).each do |field|
      pivot = build(field)

      assert_in_delta baseline, pivot[:grand_total].to_f, 0.01, "#{field.key} grand total drifted"
      assert_in_delta baseline, pivot[:category_totals].values.sum.to_f, 0.01,
                      "#{field.key} category totals drifted"
      assert_in_delta baseline, pivot[:matrix].values.flat_map(&:values).sum.to_f, 0.01,
                      "#{field.key} matrix drifted"
    end
  end

  # Two custom_values rows for the same field on one issue must not double-count: the de-dup in
  # CustomField#join_for_order_statement is what guarantees this.
  test 'duplicate custom values on one issue do not double count hours' do
    cf = IssueCustomField.create!(name: 'TA Dup', field_format: 'string',
                                  is_filter: true, is_for_all: true)
    issue = TimeEntry.where.not(issue_id: nil).first.issue
    CustomValue.create!(customized: issue, custom_field: cf, value: 'first')
    CustomValue.create!(customized: issue, custom_field: cf, value: 'second')

    baseline = scope.reorder(nil).sum(:hours).to_f
    field = Registry.find("cf_issue_#{cf.id}", User.current)

    # Guard the guard: without the de-dup this join really does multiply rows, so if this ever
    # stops holding the assertions below are no longer proving anything.
    assert_equal 2, CustomValue.where(customized: issue, custom_field: cf).count
    assert scope.where(issue_id: issue.id).exists?

    # The join must not multiply rows, which is what would silently double the hours.
    assert_equal scope.count, Pivot.apply_joins(scope, field).count,
                 'joining the custom field must not change the row count'

    pivot = build(field)
    assert_in_delta baseline, pivot[:grand_total].to_f, 0.01
    assert_in_delta baseline, pivot[:category_totals].values.sum.to_f, 0.01
  end

  test 'entries with no issue and entries with no value share one no-value bucket' do
    cf = IssueCustomField.create!(name: 'TA Sparse', field_format: 'string',
                                  is_filter: true, is_for_all: true)
    assert scope.where(issue_id: nil).exists?, 'fixtures must include an entry with no issue'

    pivot = build(Registry.find("cf_issue_#{cf.id}", User.current))

    assert_equal 1, pivot[:categories].count('(none)'), 'no-value bucket must appear exactly once'
    assert_nil pivot[:category_values]['(none)'], 'no-value bucket carries a nil group value'
  end

  test 'scope_for_value isolates one group and the no-value bucket' do
    field = Registry.find('issue_tracker', User.current)
    pivot = build(field)
    baseline = scope.reorder(nil).sum(:hours).to_f

    total = pivot[:categories].sum do |name|
      Pivot.scope_for_value(scope, field, pivot[:category_values][name]).reorder(nil).sum(:hours).to_f
    end

    assert_in_delta baseline, total, 0.01, 'per-group drill-down scopes must partition the total'
  end

  # --- Administrator-pinned permanent grouping tabs -------------------------------------------

  test 'pinning a custom field makes it a permanent grouping' do
    cf = IssueCustomField.create!(name: 'TA Customer Pinned', field_format: 'list',
                                  possible_values: %w[acme globex], is_filter: true, is_for_all: true)

    assert_empty Registry.pinned(User.current)

    TaPinnedGrouping.set_pinned(cf, true)
    assert_equal ["cf_issue_#{cf.id}"], Registry.pinned(User.current).map(&:key)
    assert Registry.find("cf_issue_#{cf.id}", User.current).pinned?

    TaPinnedGrouping.set_pinned(cf, false)
    assert_empty Registry.pinned(User.current)
  end

  test 'pinning is idempotent and keeps one row per field' do
    cf = IssueCustomField.create!(name: 'TA Twice', field_format: 'list', possible_values: %w[a],
                                  is_filter: true, is_for_all: true)

    3.times { TaPinnedGrouping.set_pinned(cf, true) }
    assert_equal 1, TaPinnedGrouping.where(custom_field_id: cf.id).count
  end

  # A pin records intent only. If the field stops being groupable the tab must disappear rather
  # than render something broken.
  test 'a pinned field that stops being groupable drops out' do
    cf = IssueCustomField.create!(name: 'TA Unpinnable', field_format: 'list',
                                  possible_values: %w[a b], is_filter: true, is_for_all: true)
    TaPinnedGrouping.set_pinned(cf, true)
    assert_equal 1, Registry.pinned(User.current).size

    cf.update!(is_filter: false)
    assert_empty Registry.pinned(User.current), 'un-ticking "Used as a filter" must drop the tab'

    cf.update!(is_filter: true, multiple: true)
    assert_equal 1, Registry.pinned(User.current).size, 'making it multi-value must retain the tab'
  end

  test 'pins for deleted custom fields are purged' do
    cf = IssueCustomField.create!(name: 'TA Doomed', field_format: 'list', possible_values: %w[a],
                                  is_filter: true, is_for_all: true)
    TaPinnedGrouping.set_pinned(cf, true)
    cf.destroy

    assert_equal 1, TaPinnedGrouping.count, 'precondition: the pin outlives the field'
    assert_empty Registry.pinned(User.current), 'a pin without a field must not render a tab'

    TaPinnedGrouping.purge_orphans!
    assert_equal 0, TaPinnedGrouping.count
  end

  test 'picker payload marks pinned fields so they are not offered twice' do
    cf = IssueCustomField.create!(name: 'TA Payload Pin', field_format: 'list',
                                  possible_values: %w[a], is_filter: true, is_for_all: true)
    TaPinnedGrouping.set_pinned(cf, true)

    entries = Registry.picker_payload(User.current).flat_map { |section| section[:fields] }
    pinned_entry = entries.detect { |f| f[:key] == "cf_issue_#{cf.id}" }

    assert pinned_entry[:pinned]
    assert_not entries.detect { |f| f[:key] == 'issue_tracker' }[:pinned]
  end

  test 'picker payload groups fields into sections' do
    payload = Registry.picker_payload(User.current)

    assert payload.any?
    payload.each do |section|
      assert section[:label].present?
      assert section[:fields].any?
      section[:fields].each { |f| assert f[:key].present? and f[:label].present? }
    end
  end
end
