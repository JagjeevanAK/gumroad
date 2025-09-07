# frozen_string_literal: true

class BalanceReconciliationWorker
  include Sidekiq::Worker

  sidekiq_options queue: "low", retry: 3

  def perform(user_id = nil, date_string = nil, auto_correct = false)
    date = date_string ? Date.parse(date_string) : Date.current

    if user_id
      user = User.find(user_id)
      reconcile_single_user(user, date, auto_correct)
    else
      reconcile_all_users(date, auto_correct)
    end
  end

  private

  def reconcile_single_user(user, date, auto_correct)
    service = BalanceReconciliationService.reconcile_user(user, date: date)

    if service.has_discrepancies?
      service.report_discrepancies
      service.auto_correct_discrepancies if auto_correct
    end
  end

  def reconcile_all_users(date, auto_correct)
    Rails.logger.info("Starting balance reconciliation for all users on #{date}")

    total_users = 0
    users_with_discrepancies = 0

    User.holding_balance.find_each do |user|
      total_users += 1

      service = BalanceReconciliationService.reconcile_user(user, date: date)

      if service.has_discrepancies?
        users_with_discrepancies += 1
        service.report_discrepancies
        service.auto_correct_discrepancies if auto_correct
      end

      # Log progress every 1000 users
      if total_users % 1000 == 0
        Rails.logger.info("Balance reconciliation progress: #{total_users} users processed, #{users_with_discrepancies} with discrepancies")
      end
    end

    Rails.logger.info("Balance reconciliation completed: #{total_users} users processed, #{users_with_discrepancies} with discrepancies")

    # Send summary alert if significant discrepancies found
    if users_with_discrepancies > total_users * 0.01 # More than 1% of users
      Bugsnag.notify(
        BalanceReconciliationWorker::HighDiscrepancyRateError.new(
          "High balance discrepancy rate: #{users_with_discrepancies}/#{total_users} users affected"
        ),
        {
          total_users: total_users,
          users_with_discrepancies: users_with_discrepancies,
          discrepancy_rate: (users_with_discrepancies.to_f / total_users * 100).round(2),
          date: date
        }
      )
    end
  end

  class HighDiscrepancyRateError < StandardError; end
end
