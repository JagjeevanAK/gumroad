# frozen_string_literal: true

class BalanceIncrementRecord < ApplicationRecord
  include Immutable

  belongs_to :purchase
  belongs_to :balance_transaction, optional: true

  validates :purchase_id, presence: true, uniqueness: true

  def self.create_for_purchase!(purchase)
    create!(purchase: purchase)
  rescue ActiveRecord::RecordNotUnique
    # Record already exists, which means balance was already incremented
    find_by!(purchase: purchase)
  end

  def mark_completed!(balance_transaction)
    update!(balance_transaction: balance_transaction)
  end
end
