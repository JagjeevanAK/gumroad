# frozen_string_literal: true

# Balance Monitoring Configuration
# This initializer sets up monitoring and alerting for balance-related issues

Rails.application.configure do
  # Schedule balance reconciliation jobs
  if defined?(Sidekiq)
    # Daily balance reconciliation at 2 AM UTC
    Sidekiq.configure_server do |config|
      config.on(:startup) do
        # Schedule daily balance reconciliation
        if defined?(Sidekiq::Scheduler)
          Sidekiq.set_schedule('daily_balance_reconciliation', {
            'cron' => '0 2 * * *',
            'class' => 'BalanceReconciliationWorker',
            'args' => [nil, nil, false], # all users, current date, no auto-correct
            'description' => 'Daily balance reconciliation check'
          })

          # Schedule weekly cleanup of processed Stripe events
          Sidekiq.set_schedule('weekly_stripe_events_cleanup', {
            'cron' => '0 3 * * 0',
            'class' => 'CleanupProcessedStripeEventsWorker',
            'args' => [90], # Keep events for 90 days
            'description' => 'Weekly cleanup of old processed Stripe events'
          })
        end
      end
    end
  end

  # Configure balance monitoring thresholds
  config.balance_monitoring = ActiveSupport::OrderedOptions.new
  config.balance_monitoring.max_discrepancy_rate = 0.01 # 1% of users
  config.balance_monitoring.max_individual_discrepancy_cents = 10_000 # $100
  config.balance_monitoring.alert_channels = %w[slack email bugsnag]

  # Configure automatic correction thresholds
  config.balance_monitoring.auto_correct_enabled = Rails.env.production? ? false : true
  config.balance_monitoring.auto_correct_max_amount_cents = 1_000 # $10
end

# Custom metrics for monitoring
if defined?(StatsD)
  module BalanceMetrics
    def self.increment_balance_discrepancy(type:, amount_cents: 0)
      StatsD.increment('balance.discrepancy', tags: ["type:#{type}"])
      StatsD.histogram('balance.discrepancy.amount', amount_cents.abs, tags: ["type:#{type}"])
    end

    def self.increment_balance_correction(type:, amount_cents: 0)
      StatsD.increment('balance.correction', tags: ["type:#{type}"])
      StatsD.histogram('balance.correction.amount', amount_cents.abs, tags: ["type:#{type}"])
    end

    def self.increment_payout_failure(reason:)
      StatsD.increment('payout.failure', tags: ["reason:#{reason}"])
    end

    def self.increment_webhook_processing(event_type:, status:)
      StatsD.increment('webhook.processing', tags: ["event_type:#{event_type}", "status:#{status}"])
    end

    def self.track_balance_reconciliation_duration(duration_ms)
      StatsD.histogram('balance.reconciliation.duration', duration_ms)
    end
  end
end

# Health check endpoint for balance system
if defined?(Rails::HealthCheck)
  Rails::HealthCheck.configure do |config|
    config.add_check :balance_system do
      # Check if there are any critical balance discrepancies
      recent_discrepancies = BalanceAuditLog.where(
        operation: 'reconciliation',
        created_at: 1.hour.ago..Time.current
      ).count

      if recent_discrepancies > 10
        { status: :unhealthy, message: "High number of recent balance discrepancies: #{recent_discrepancies}" }
      else
        { status: :healthy, message: "Balance system operating normally" }
      end
    end
  end
end
