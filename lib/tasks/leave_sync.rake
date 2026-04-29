namespace :redmine_time_analytics do
  desc 'Sync leave requests from configured mailbox (MODE=incremental|historical)'
  task sync_leave_mailbox: :environment do
    mode = ENV.fetch('MODE', 'incremental')
    service = RedmineTimeAnalytics::LeaveSyncService.new
    result = service.sync!(mode: mode.to_sym)

    puts "Processed: #{result.processed_count}"
    puts "Imported: #{result.imported_count}"
    puts "Flagged: #{result.flagged_count}"
    if result.errors.any?
      puts 'Errors:'
      result.errors.uniq.each { |error| puts "- #{error}" }
    end
  end
end
