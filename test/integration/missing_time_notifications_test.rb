# frozen_string_literal: true

require File.expand_path('../../../../test/test_helper', __dir__)

class MissingTimeNotificationsTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :trackers, :issue_statuses, :enumerations, :issues, :time_entries

  test 'admin can save independent modes and remove all rows without restoring legacy schedules' do
    with_settings plugin_redmine_time_analytics: {
      'missing_time_crons' => ['0 18 * * 5'], 'leave_sync_enabled' => '0'
    } do
      log_user('admin', 'admin')
      get '/settings/plugin/redmine_time_analytics'
      assert_response :success
      assert_select 'input[name="settings[missing_time_schedules][0][weekly]"][checked]', count: 1
      assert_select 'input[name="settings[missing_time_schedules][0][daily]"][checked]', count: 0

      post '/settings/plugin/redmine_time_analytics', params: {
        settings: {
          missing_time_enabled: '1', missing_time_recipients: 'admin@example.com',
          leave_sync_enabled: '0', missing_time_schedules: {
            '_empty' => { cron: '' },
            '0' => { cron: '0 18 * * 5', weekly: '1', daily: '1' },
            '2' => { cron: '0 8 * * *', weekly: '0', daily: '1' },
            '3' => { cron: '0 9 * * *', weekly: '0', daily: '0' }
          }
        }
      }
      assert_redirected_to '/settings/plugin/redmine_time_analytics'
      stored = Setting.find_by!(name: 'plugin_redmine_time_analytics').reload.value
      assert_equal '0', stored['leave_sync_enabled']
      rows = TaTeamSetting.missing_time_schedules(stored)
      assert_equal [
        { cron: '0 18 * * 5', weekly: true, daily: true },
        { cron: '0 8 * * *', weekly: false, daily: true },
        { cron: '0 9 * * *', weekly: false, daily: false }
      ], rows

      post '/settings/plugin/redmine_time_analytics', params: {
        settings: { missing_time_enabled: '1', missing_time_recipients: 'admin@example.com',
                    missing_time_schedules: { '_empty' => { cron: '' } } }
      }
      assert_redirected_to '/settings/plugin/redmine_time_analytics'
      assert_empty TaTeamSetting.missing_time_settings[:schedules]
    end
  end

  test 'daily and weekly windows preserve leave exclusions holidays membership and active project rules' do
    with_settings non_working_week_days: %w[6 7], timelog_accept_future_dates: '1' do
      user = User.find(2)
      team = TaTeam.create!(name: 'Missing time regression team')
      monday = Date.new(2026, 10, 5)
      TaTeamMembership.create!(team: team, user: user, role: 'member', start_date: monday, end_date: monday + 4)
      CustomHoliday.create!(name: 'Regression holiday', start_date: monday, end_date: monday, active: true)
      TaLeaveRecord.create!(user: user, leave_date: monday + 1, leave_fraction: 1, status: 'confirmed')
      half_day = TaLeaveRecord.create!(user: user, leave_date: monday + 2, leave_fraction: 0.5, status: 'confirmed')
      TaTeamSetting.create!(user: user, setting_type: 'exclusion', start_date: monday + 3, end_date: monday + 3, active: true)

      service = RedmineTimeAnalytics::MissingTimeNotificationService.new
      weekly_range, = service.send(:resolve_date_range, monday + 7, :weekly)
      assert_equal monday..monday + 6, weekly_range
      missing = service.send(:users_missing_time_for_range, weekly_range)
      assert_equal [half_day.leave_date, monday + 4], missing.fetch(team).fetch(user)
      daily_range, = service.send(:resolve_date_range, monday + 2, :daily)
      assert_equal [half_day.leave_date], service.send(:users_missing_time_for_range, daily_range).fetch(team).fetch(user)
      assert_empty service.send(:users_missing_time_for_range, monday + 5..monday + 5)
      assert_empty service.send(:users_missing_time_for_range, monday + 7..monday + 7)

      entry = TimeEntry.find(1).dup
      entry.assign_attributes(spent_on: monday + 4, hours: 1)
      entry.save!
      assert_equal [half_day.leave_date], service.send(:users_missing_time_for_range, weekly_range).fetch(team).fetch(user)
      entry.project.update_column(:status, Project::STATUS_ARCHIVED)
      assert_equal [half_day.leave_date, monday + 4], service.send(:users_missing_time_for_range, weekly_range).fetch(team).fetch(user)
    end
  end
end
