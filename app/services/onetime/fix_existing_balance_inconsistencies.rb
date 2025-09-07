# frozen_string_literal: true

# One-time script to fix existing balance inconsistencies
# Run with: rails runner "Onetime::FixExistingBalanceInconsistencies.new.process"

module Onetime
  class FixExistingBalanceInconsistencies
    include CurrencyHelper

    def initialize(dry_run: true, batch_size: 100)
      @dry_run = dry_run
      @batch_size = batch_size
      @stats = {
        users_processed: 0,
        users_with_issues: 0,
        duplicate_increments_fixed: 0,
        balance_mismatches_fixed: 0,
        total_amount_corrected_cents: 0
      }
    end

    def process
      Rails.logger.info("Starting balance inconsistency fix (dry_run: #{@dry_run})")

      # Fix the specific users mentioned in the task
      fix_specific_users

      # Then run a broader check
      fix_all_users_with_issues

      report_results
    end

    private

    def fix_specific_users
      # UID: 11152070 - Double balance increment
      fix_user_double_increments(11152070, [246694096, 270145984, 271240392, 275937297, 280598592, 285010678])

      # UID: 366191 - Chargeback routing issue
      fix_user_chargeback_routing(366191)

      # UID: 20913918 - Negative balance on country change
      fix_user_negative_balance_country_change(20913918)

      # UID: 6888879 - Stripe loan paydown issue
      fix_user_loan_paydown_issue(6888879)
    end

    def fix_user_double_increments(user_id, purchase_ids)
      user = User.find_by(id: user_id)
      return unless user

      Rails.logger.info("Fixing double increments for user #{user_id}")

      purchase_ids.each do |purchase_id|
        purchase = user.sales.find_by(id: purchase_id)
        next unless purchase

        balance_transactions = purchase.balance_transactions
        if balance_transactions.count > 1
          fix_duplicate_balance_transactions(purchase, balance_transactions)
          @stats[:duplicate_increments_fixed] += 1
        end
      end

      @stats[:users_with_issues] += 1
    end

    def fix_user_chargeback_routing(user_id)
      user = User.find_by(id: user_id)
      return unless user

      Rails.logger.info("Fixing chargeback routing for user #{user_id}")

      # Find disputes with credits on deleted accounts
      user.disputes.each do |dispute|
        next unless dispute.won?

        dispute.credits.each do |credit|
          if credit.merchant_account&.deleted?
            route_credit_to_active_account(credit, user)
          end
        end
      end

      @stats[:users_with_issues] += 1
    end

    def fix_user_negative_balance_country_change(user_id)
      user = User.find_by(id: user_id)
      return unless user

      Rails.logger.info("Fixing negative balance country change for user #{user_id}")

      # Find negative balances that should have been transferred
      negative_balances = user.unpaid_balances.where("amount_cents < 0")

      negative_balances.each do |balance|
        transfer_negative_balance_to_gumroad_account(balance)
      end

      @stats[:users_with_issues] += 1 if negative_balances.any?
    end

    def fix_user_loan_paydown_issue(user_id)
      user = User.find_by(id: user_id)
      return unless user

      Rails.logger.info("Fixing loan paydown issue for user #{user_id}")

      # Find credits with negative amounts that might be incorrectly applied
      problematic_credits = user.credits.where("amount_cents < 0")
                                       .where("json_data->'$.stripe_loan_paydown_id' IS NOT NULL")

      problematic_credits.each do |credit|
        # Check if this was a duplicate processing
        if duplicate_loan_paydown_credit?(credit)
          reverse_duplicate_loan_paydown_credit(credit)
        end
      end

      @stats[:users_with_issues] += 1 if problematic_credits.any?
    end

    def fix_all_users_with_issues
      Rails.logger.info("Scanning all users for balance issues")

      User.holding_balance.find_in_batches(batch_size: @batch_size) do |users|
        users.each do |user|
          @stats[:users_processed] += 1

          service = BalanceReconciliationService.reconcile_user(user)

          if service.has_discrepancies?
            @stats[:users_with_issues] += 1

            if @dry_run
              Rails.logger.info("User #{user.id} has #{service.discrepancies.count} discrepancies (dry run)")
            else
              service.auto_correct_discrepancies
              Rails.logger.info("Fixed discrepancies for user #{user.id}")
            end
          end

          # Log progress
          if @stats[:users_processed] % 1000 == 0
            Rails.logger.info("Progress: #{@stats[:users_processed]} users processed, #{@stats[:users_with_issues]} with issues")
          end
        end
      end
    end

    def fix_duplicate_balance_transactions(purchase, balance_transactions)
      return if @dry_run

      # Keep the first transaction, remove duplicates
      transactions_to_remove = balance_transactions.order(:created_at)[1..-1]

      ActiveRecord::Base.transaction do
        transactions_to_remove.each do |transaction|
          balance = transaction.balance
          balance.with_lock do
            # Reverse the balance increment
            balance.decrement(:amount_cents, transaction.issued_amount_net_cents)
            balance.decrement(:holding_amount_cents, transaction.holding_amount_net_cents)
            balance.save!

            @stats[:total_amount_corrected_cents] += transaction.issued_amount_net_cents
          end

          # Create audit log
          BalanceAuditLog.log_balance_change!(
            balance: balance,
            operation: 'reconciliation',
            amount_cents_before: balance.amount_cents + transaction.issued_amount_net_cents,
            amount_cents_after: balance.amount_cents,
            triggered_by: "FixExistingBalanceInconsistencies",
            source: transaction,
            metadata: {
              fix_type: 'duplicate_balance_increment_removal',
              purchase_id: purchase.id
            }
          )

          # Soft delete the duplicate transaction
          transaction.update!(deleted_at: Time.current)
        end
      end
    end

    def route_credit_to_active_account(credit, user)
      return if @dry_run

      active_account = user.active_merchant_account
      return unless active_account

      # Create new credit on active account
      new_credit = Credit.create!(
        user: user,
        merchant_account: active_account,
        amount_cents: credit.amount_cents
      )

      # Create balance transaction for new credit
      balance_transaction_amount = BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: new_credit.get_usd_cents(active_account.currency, credit.amount_cents),
        net_cents: new_credit.get_usd_cents(active_account.currency, credit.amount_cents)
      )

      balance_transaction_holding_amount = BalanceTransaction::Amount.new(
        currency: active_account.currency,
        gross_cents: credit.amount_cents,
        net_cents: credit.amount_cents
      )

      BalanceTransaction.create!(
        user: user,
        merchant_account: active_account,
        credit: new_credit,
        issued_amount: balance_transaction_amount,
        holding_amount: balance_transaction_holding_amount
      )

      # Mark original credit as transferred
      credit.update!(
        json_data: credit.json_data.merge(
          transferred_to_account_id: active_account.id,
          transferred_at: Time.current
        )
      )
    end

    def transfer_negative_balance_to_gumroad_account(balance)
      return if @dry_run

      gumroad_account = MerchantAccount.gumroad(balance.merchant_account.charge_processor_id)

      # Create offsetting credit on original account
      Credit.create_for_balance_transfer!(
        user: balance.user,
        merchant_account: balance.merchant_account,
        amount_cents: -balance.amount_cents,
        transfer_reason: "negative_balance_country_change_fix"
      )

      # Create corresponding debit on Gumroad account
      Credit.create_for_balance_transfer!(
        user: balance.user,
        merchant_account: gumroad_account,
        amount_cents: balance.amount_cents,
        transfer_reason: "negative_balance_country_change_fix"
      )

      balance.mark_forfeited!
    end

    def duplicate_loan_paydown_credit?(credit)
      # Check if there are multiple credits with the same loan paydown ID
      stripe_loan_paydown_id = credit.stripe_loan_paydown_id
      return false unless stripe_loan_paydown_id

      credit.user.credits
           .where("json_data->'$.stripe_loan_paydown_id' = ?", stripe_loan_paydown_id)
           .count > 1
    end

    def reverse_duplicate_loan_paydown_credit(credit)
      return if @dry_run

      # Create offsetting credit to reverse the duplicate
      Credit.create!(
        user: credit.user,
        merchant_account: credit.merchant_account,
        amount_cents: -credit.amount_cents,
        json_data: {
          reversal_of_credit_id: credit.id,
          reversal_reason: "duplicate_loan_paydown_fix"
        }
      )

      # Mark original as reversed
      credit.update!(
        json_data: credit.json_data.merge(
          reversed_at: Time.current,
          reversal_reason: "duplicate_loan_paydown_fix"
        )
      )
    end

    def report_results
      Rails.logger.info("Balance inconsistency fix completed:")
      Rails.logger.info("  Users processed: #{@stats[:users_processed]}")
      Rails.logger.info("  Users with issues: #{@stats[:users_with_issues]}")
      Rails.logger.info("  Duplicate increments fixed: #{@stats[:duplicate_increments_fixed]}")
      Rails.logger.info("  Balance mismatches fixed: #{@stats[:balance_mismatches_fixed]}")
      Rails.logger.info("  Total amount corrected: #{formatted_dollar_amount(@stats[:total_amount_corrected_cents])}")
      Rails.logger.info("  Dry run: #{@dry_run}")
    end
  end
end
