# frozen_string_literal: true

class AddExclusionDatesToTaTeamSettings < ActiveRecord::Migration[6.1]
  def up
    add_column :ta_team_settings, :start_date, :date unless column_exists?(:ta_team_settings, :start_date)
    add_column :ta_team_settings, :end_date, :date unless column_exists?(:ta_team_settings, :end_date)

    if column_exists?(:ta_team_settings, :start_date)
      TaTeamSetting.reset_column_information
      TaTeamSetting.where(setting_type: 'exclusion').find_each do |setting|
        next if setting.start_date.present?

        setting.update_columns(start_date: setting.created_at&.to_date || Date.current)
      end
    end

    add_index :ta_team_settings, :start_date unless index_exists?(:ta_team_settings, :start_date)
    add_index :ta_team_settings, :end_date unless index_exists?(:ta_team_settings, :end_date)
  end

  def down
    remove_index :ta_team_settings, :start_date if index_exists?(:ta_team_settings, :start_date)
    remove_index :ta_team_settings, :end_date if index_exists?(:ta_team_settings, :end_date)
    remove_column :ta_team_settings, :start_date if column_exists?(:ta_team_settings, :start_date)
    remove_column :ta_team_settings, :end_date if column_exists?(:ta_team_settings, :end_date)
  end
end
