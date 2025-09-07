# frozen_string_literal: true

class ProcessedStripeEvent < ApplicationRecord
  include Immutable

  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true

  def self.mark_processed!(stripe_event_id, event_type, stripe_account_id: nil, metadata: {})
    create!(
      stripe_event_id: stripe_event_id,
      event_type: event_type,
      stripe_account_id: stripe_account_id,
      metadata: metadata
    )
  rescue ActiveRecord::RecordNotUnique
    # Event already processed
    find_by!(stripe_event_id: stripe_event_id)
  end

  def self.already_processed?(stripe_event_id)
    exists?(stripe_event_id: stripe_event_id)
  end

  def self.cleanup_old_events(older_than: 90.days.ago)
    where("created_at < ?", older_than).delete_all
  end
end
