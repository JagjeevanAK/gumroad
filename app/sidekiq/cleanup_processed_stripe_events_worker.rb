# frozen_string_literal: true

class CleanupProcessedStripeEventsWorker
  include Sidekiq::Worker

  sidekiq_options queue: "low", retry: 2

  def perform(older_than_days = 90)
    older_than = older_than_days.days.ago

    Rails.logger.info("Cleaning up processed Stripe events older than #{older_than}")

    deleted_count = ProcessedStripeEvent.cleanup_old_events(older_than)

    Rails.logger.info("Cleaned up #{deleted_count} processed Stripe events")
  end
end
