# frozen_string_literal: true

class BalanceAuditLog < ApplicationRecord
  include Immutable

  belongs_to :balance
  belongs_to :source, polymorphic: true, optional: true

  validates :balance_id, presence: true
  validates :operation, presence: true

  OPERATIONS = %w[
    increment
    decrement
    transfer_in
    transfer_out
    forfeit
    reconciliation
  ].freeze

  validates :operation, inclusion: { in: OPERATIONS }

  def self.log_balance_change!(balance:, operation:, amount_cents_before:, amount_cents_after:,
                               holding_amount_cents_before: nil, holding_amount_cents_after: nil,
                               triggered_by:, source: nil, metadata: {})
    create!(
      balance: balance,
      operation: operation,
      amount_cents_before: amount_cents_before,
      amount_cents_after: amount_cents_after,
      holding_amount_cents_before: holding_amount_cents_before,
      holding_amount_cents_after: holding_amount_cents_after,
      triggered_by: triggered_by,
      source: source,
      metadata: metadata
    )
  end

  def amount_change
    return nil if amount_cents_before.nil? || amount_cents_after.nil?
    amount_cents_after - amount_cents_before
  end

  def holding_amount_change
    return nil if holding_amount_cents_before.nil? || holding_amount_cents_after.nil?
    holding_amount_cents_after - holding_amount_cents_before
  end
end
