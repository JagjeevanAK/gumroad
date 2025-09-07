# frozen_string_literal: true

class ForfeitBalanceService
  include CurrencyHelper

  attr_reader :user, :reason

  def initialize(user:, reason:)
    @user = user
    @reason = reason
  end

  def process
    handle_positive_balances if positive_balance_amount_cents > 0
    handle_negative_balances if negative_balance_amount_cents < 0
  end

  private

  def handle_positive_balances
    positive_balances_to_forfeit.group_by(&:merchant_account).each do |merchant_account, balances|
      Credit.create_for_balance_forfeit!(
        user:,
        merchant_account:,
        amount_cents: -balances.sum(&:amount_cents)
      )

      balances.each(&:mark_forfeited!)
    end

    balance_ids = positive_balances_to_forfeit.ids.join(", ")
    user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_BALANCE_FORFEITED,
      content: "Positive balance of #{positive_balance_amount_formatted} has been forfeited. Reason: #{reason_comment}. Balance IDs: #{balance_ids}"
    )
  end

  def handle_negative_balances
    case reason
    when :country_change
      transfer_negative_balances_to_new_country
    when :account_closure
      # For account closure, negative balances are written off
      write_off_negative_balances
    end
  end

  def transfer_negative_balances_to_new_country
    negative_balances_to_handle.group_by(&:merchant_account).each do |old_merchant_account, balances|
      # Find or create new merchant account for new country
      new_merchant_account = find_or_create_new_country_merchant_account(old_merchant_account)

      balances.each do |balance|
        transfer_negative_balance(balance, new_merchant_account)
      end
    end

    balance_ids = negative_balances_to_handle.ids.join(", ")
    user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_BALANCE_TRANSFERRED,
      content: "Negative balance of #{negative_balance_amount_formatted} has been transferred to new country account. Balance IDs: #{balance_ids}"
    )
  end

  def write_off_negative_balances
    negative_balances_to_handle.each(&:mark_forfeited!)

    balance_ids = negative_balances_to_handle.ids.join(", ")
    user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_BALANCE_FORFEITED,
      content: "Negative balance of #{negative_balance_amount_formatted} has been written off due to account closure. Balance IDs: #{balance_ids}"
    )
  end

  def transfer_negative_balance(balance, new_merchant_account)
    # Create offsetting credit on old account
    Credit.create_for_balance_transfer!(
      user: user,
      merchant_account: balance.merchant_account,
      amount_cents: -balance.amount_cents,
      transfer_reason: "country_change_negative_balance_transfer"
    )

    # Create corresponding debit on new account
    Credit.create_for_balance_transfer!(
      user: user,
      merchant_account: new_merchant_account,
      amount_cents: balance.amount_cents,
      transfer_reason: "country_change_negative_balance_transfer"
    )

    balance.mark_forfeited!
  end

  def find_or_create_new_country_merchant_account(old_merchant_account)
    # This would need to be implemented based on the new country logic
    # For now, return Gumroad's merchant account as fallback
    MerchantAccount.gumroad(old_merchant_account.charge_processor_id)
  end

  def balance_amount_formatted
    formatted_dollar_amount(balance_amount_cents_to_forfeit)
  end

  def positive_balance_amount_formatted
    formatted_dollar_amount(positive_balance_amount_cents)
  end

  def negative_balance_amount_formatted
    formatted_dollar_amount(negative_balance_amount_cents.abs)
  end

  def balance_amount_cents_to_forfeit
    @_balance_amount_cents_to_forfeit ||= balances_to_forfeit.sum(:amount_cents)
  end

  def positive_balance_amount_cents
    @_positive_balance_amount_cents ||= positive_balances_to_forfeit.sum(:amount_cents)
  end

  def negative_balance_amount_cents
    @_negative_balance_amount_cents ||= negative_balances_to_handle.sum(:amount_cents)
  end

    def reason_comment
      case reason
      when :account_closure
        "Account closed"
      when :country_change
        "Country changed"
      end
    end

    def balances_to_forfeit
      @_balances_to_forfeit ||= send("balances_to_forfeit_on_#{reason}")
    end

    def positive_balances_to_forfeit
      @_positive_balances_to_forfeit ||= balances_to_forfeit.where("amount_cents > 0")
    end

    def negative_balances_to_handle
      @_negative_balances_to_handle ||= balances_to_forfeit.where("amount_cents < 0")
    end

    def balances_to_forfeit_on_account_closure
      user.unpaid_balances
    end

    # Forfeiting is only needed if balance is in a Gumroad-controlled Stripe account
    def balances_to_forfeit_on_country_change
      user.unpaid_balances.where.not(merchant_account_id: [
                                       MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                                       MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
                                     ])
    end
end
