# frozen_string_literal: true

class BalanceReconciliationService
  include CurrencyHelper

  attr_reader :user, :date, :discrepancies

  def initialize(user: nil, date: Date.current)
    @user = user
    @date = date
    @discrepancies = []
  end

  def self.reconcile_all_users(date: Date.current)
    User.holding_balance.find_each do |user|
      service = new(user: user, date: date)
      service.reconcile
      service.report_discrepancies if service.has_discrepancies?
    end
  end

  def self.reconcile_user(user, date: Date.current)
    service = new(user: user, date: date)
    service.reconcile
    service
  end

  def reconcile
    return reconcile_all_users if user.nil?

    @discrepancies = []

    # Check balance calculation consistency
    check_balance_transaction_consistency

    # Check Stripe balance consistency (if applicable)
    check_stripe_balance_consistency

    # Check for duplicate balance increments
    check_duplicate_balance_increments

    # Check for orphaned balance transactions
    check_orphaned_balance_transactions

    self
  end

  def has_discrepancies?
    discrepancies.any?
  end

  def report_discrepancies
    return unless has_discrepancies?

    Rails.logger.error("Balance discrepancies found for user #{user.id}:")
    discrepancies.each do |discrepancy|
      Rails.logger.error("  - #{discrepancy[:type]}: #{discrepancy[:message]}")
    end

    # Create admin comment for tracking
    user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_BALANCE_DISCREPANCY,
      content: "Balance discrepancies detected: #{discrepancies.map { |d| d[:message] }.join('; ')}"
    )

    # Send alert to monitoring system
    send_balance_mismatch_alert
  end

  def auto_correct_discrepancies
    discrepancies.each do |discrepancy|
      case discrepancy[:type]
      when :duplicate_balance_increment
        correct_duplicate_balance_increment(discrepancy)
      when :orphaned_balance_transaction
        correct_orphaned_balance_transaction(discrepancy)
      when :balance_calculation_mismatch
        correct_balance_calculation_mismatch(discrepancy)
      end
    end
  end

  private

  def reconcile_all_users
    User.holding_balance.find_each do |user|
      self.class.reconcile_user(user, date: date)
    end
  end

  def check_balance_transaction_consistency
    user.unpaid_balances.each do |balance|
      calculated_amount = balance.balance_transactions.sum(:issued_amount_net_cents)
      calculated_holding_amount = balance.balance_transactions.sum(:holding_amount_net_cents)

      if balance.amount_cents != calculated_amount
        add_discrepancy(
          type: :balance_calculation_mismatch,
          message: "Balance #{balance.id} amount mismatch: stored=#{balance.amount_cents}, calculated=#{calculated_amount}",
          balance: balance,
          expected: calculated_amount,
          actual: balance.amount_cents
        )
      end

      if balance.holding_amount_cents != calculated_holding_amount
        add_discrepancy(
          type: :holding_balance_calculation_mismatch,
          message: "Balance #{balance.id} holding amount mismatch: stored=#{balance.holding_amount_cents}, calculated=#{calculated_holding_amount}",
          balance: balance,
          expected: calculated_holding_amount,
          actual: balance.holding_amount_cents
        )
      end
    end
  end

  def check_stripe_balance_consistency
    return unless user.has_stripe_account_connected?

    user.merchant_accounts.stripe.each do |merchant_account|
      next if merchant_account.deleted?

      begin
        stripe_balance = fetch_stripe_balance(merchant_account)
        gumroad_balance = calculate_gumroad_balance_for_account(merchant_account)

        if stripe_balance != gumroad_balance
          add_discrepancy(
            type: :stripe_balance_mismatch,
            message: "Stripe balance mismatch for account #{merchant_account.id}: stripe=#{stripe_balance}, gumroad=#{gumroad_balance}",
            merchant_account: merchant_account,
            expected: stripe_balance,
            actual: gumroad_balance
          )
        end
      rescue Stripe::StripeError => e
        Rails.logger.error("Error fetching Stripe balance for account #{merchant_account.id}: #{e.message}")
      end
    end
  end

  def check_duplicate_balance_increments
    # Find purchases with multiple balance transactions
    duplicate_purchases = user.sales.joins(:balance_transactions)
                             .group('purchases.id')
                             .having('COUNT(balance_transactions.id) > 1')
                             .pluck('purchases.id')

    duplicate_purchases.each do |purchase_id|
      purchase = Purchase.find(purchase_id)
      balance_transactions = purchase.balance_transactions

      add_discrepancy(
        type: :duplicate_balance_increment,
        message: "Purchase #{purchase_id} has #{balance_transactions.count} balance transactions",
        purchase: purchase,
        balance_transactions: balance_transactions
      )
    end
  end

  def check_orphaned_balance_transactions
    # Find balance transactions without associated purchases/disputes/refunds/credits
    orphaned_transactions = user.balance_transactions
                               .where(purchase_id: nil, dispute_id: nil, refund_id: nil, credit_id: nil)

    orphaned_transactions.each do |transaction|
      add_discrepancy(
        type: :orphaned_balance_transaction,
        message: "Balance transaction #{transaction.id} has no associated source",
        balance_transaction: transaction
      )
    end
  end

  def fetch_stripe_balance(merchant_account)
    stripe_balance = Stripe::Balance.retrieve(
      {},
      { stripe_account: merchant_account.charge_processor_merchant_id }
    )

    available_balance = stripe_balance.available.find { |b| b.currency.upcase == merchant_account.currency }
    available_balance&.amount || 0
  end

  def calculate_gumroad_balance_for_account(merchant_account)
    user.unpaid_balances
        .where(merchant_account: merchant_account)
        .sum(:holding_amount_cents)
  end

  def add_discrepancy(discrepancy)
    @discrepancies << discrepancy
  end

  def correct_duplicate_balance_increment(discrepancy)
    purchase = discrepancy[:purchase]
    balance_transactions = discrepancy[:balance_transactions]

    # Keep the first transaction, remove duplicates
    transactions_to_remove = balance_transactions[1..-1]

    ActiveRecord::Base.transaction do
      transactions_to_remove.each do |transaction|
        # Reverse the balance increment
        balance = transaction.balance
        balance.with_lock do
          balance.decrement(:amount_cents, transaction.issued_amount_net_cents)
          balance.decrement(:holding_amount_cents, transaction.holding_amount_net_cents)
          balance.save!
        end

        # Log the correction
        BalanceAuditLog.log_balance_change!(
          balance: balance,
          operation: 'reconciliation',
          amount_cents_before: balance.amount_cents + transaction.issued_amount_net_cents,
          amount_cents_after: balance.amount_cents,
          holding_amount_cents_before: balance.holding_amount_cents + transaction.holding_amount_net_cents,
          holding_amount_cents_after: balance.holding_amount_cents,
          triggered_by: "BalanceReconciliation#duplicate_correction",
          source: transaction,
          metadata: { correction_type: 'duplicate_balance_increment_removal' }
        )

        # Soft delete the duplicate transaction
        transaction.update!(deleted_at: Time.current)
      end
    end

    Rails.logger.info("Corrected duplicate balance increment for purchase #{purchase.id}")
  end

  def correct_orphaned_balance_transaction(discrepancy)
    # For now, just log orphaned transactions - manual review needed
    Rails.logger.warn("Orphaned balance transaction found: #{discrepancy[:balance_transaction].id}")
  end

  def correct_balance_calculation_mismatch(discrepancy)
    balance = discrepancy[:balance]
    expected = discrepancy[:expected]
    actual = discrepancy[:actual]

    ActiveRecord::Base.transaction do
      balance.with_lock do
        balance.update!(amount_cents: expected)

        BalanceAuditLog.log_balance_change!(
          balance: balance,
          operation: 'reconciliation',
          amount_cents_before: actual,
          amount_cents_after: expected,
          triggered_by: "BalanceReconciliation#calculation_correction",
          source: balance,
          metadata: {
            correction_type: 'balance_calculation_mismatch',
            difference: expected - actual
          }
        )
      end
    end

    Rails.logger.info("Corrected balance calculation mismatch for balance #{balance.id}")
  end

  def send_balance_mismatch_alert
    # Integration with monitoring system (e.g., Bugsnag, Datadog, etc.)
    Bugsnag.notify(
      BalanceDiscrepancyError.new("Balance discrepancies found for user #{user.id}"),
      {
        user_id: user.id,
        discrepancies: discrepancies,
        date: date
      }
    )
  end

  class BalanceDiscrepancyError < StandardError; end
end
