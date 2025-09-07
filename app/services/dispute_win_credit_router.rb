# frozen_string_literal: true

class DisputeWinCreditRouter
  include CurrencyHelper

  attr_reader :dispute, :amount_cents, :currency

  def initialize(dispute:, amount_cents:, currency:)
    @dispute = dispute
    @amount_cents = amount_cents
    @currency = currency
  end

  def self.route_credit(dispute:, amount_cents:, currency:)
    new(dispute: dispute, amount_cents: amount_cents, currency: currency).route_credit
  end

  def route_credit
    target_merchant_account = determine_target_merchant_account

    if needs_account_transfer?
      perform_account_transfer(target_merchant_account)
    end

    create_dispute_win_credit(target_merchant_account)
  end

  private

  def determine_target_merchant_account
    original_account = dispute.disputable.merchant_account

    # If original account is active, use it
    return original_account if original_account&.active?

    # Find active account for the same processor and user
    active_account = dispute.seller.merchant_accounts
                            .where(charge_processor_id: original_account.charge_processor_id)
                            .where(deleted_at: nil)
                            .where(currency: currency)
                            .first

    # Fallback to Gumroad account if no active account found
    active_account || MerchantAccount.gumroad(original_account.charge_processor_id)
  end

  def needs_account_transfer?
    original_account = dispute.disputable.merchant_account
    target_account = determine_target_merchant_account

    original_account != target_account && original_account&.deleted?
  end

  def perform_account_transfer(target_account)
    original_account = dispute.disputable.merchant_account

    Rails.logger.info(
      "DisputeWinCreditRouter: Transferring dispute win credit from deleted account #{original_account.id} " \
      "to active account #{target_account.id} for dispute #{dispute.id}"
    )

    # Create transfer record for audit trail
    BalanceAuditLog.log_balance_change!(
      balance: nil, # No specific balance for account transfers
      operation: 'transfer_out',
      amount_cents_before: 0,
      amount_cents_after: 0,
      triggered_by: "DisputeWinCreditRouter##{dispute.id}",
      source: dispute,
      metadata: {
        from_account_id: original_account.id,
        to_account_id: target_account.id,
        reason: 'dispute_win_account_transfer',
        amount_cents: amount_cents,
        currency: currency
      }
    )
  end

  def create_dispute_win_credit(merchant_account)
    Credit.create_for_dispute_win!(
      dispute: dispute,
      merchant_account: merchant_account,
      amount_cents: amount_cents,
      currency: currency
    )

    Rails.logger.info(
      "DisputeWinCreditRouter: Created dispute win credit of #{formatted_dollar_amount(amount_cents, currency: currency)} " \
      "for dispute #{dispute.id} on account #{merchant_account.id}"
    )
  end
end
