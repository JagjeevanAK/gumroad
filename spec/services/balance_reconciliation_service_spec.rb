# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BalanceReconciliationService, type: :service do
  let(:user) { create(:user) }
  let(:service) { described_class.new(user: user) }

  describe '#reconcile' do
    context 'when balances are consistent' do
      let!(:balance) { create(:balance, user: user, amount_cents: 1000, holding_amount_cents: 1000) }
      let!(:balance_transaction) do
        create(:balance_transaction,
               user: user,
               balance: balance,
               issued_amount_net_cents: 1000,
               holding_amount_net_cents: 1000)
      end

      it 'finds no discrepancies' do
        service.reconcile
        expect(service.has_discrepancies?).to be false
      end
    end

    context 'when balance calculation is inconsistent' do
      let!(:balance) { create(:balance, user: user, amount_cents: 1000, holding_amount_cents: 1000) }
      let!(:balance_transaction) do
        create(:balance_transaction,
               user: user,
               balance: balance,
               issued_amount_net_cents: 500,  # Mismatch!
               holding_amount_net_cents: 1000)
      end

      it 'detects balance calculation mismatch' do
        service.reconcile
        expect(service.has_discrepancies?).to be true

        discrepancy = service.discrepancies.first
        expect(discrepancy[:type]).to eq(:balance_calculation_mismatch)
        expect(discrepancy[:expected]).to eq(500)
        expect(discrepancy[:actual]).to eq(1000)
      end
    end

    context 'when purchase has duplicate balance transactions' do
      let!(:purchase) { create(:purchase, seller: user) }
      let!(:balance) { create(:balance, user: user) }
      let!(:transaction1) { create(:balance_transaction, user: user, purchase: purchase, balance: balance) }
      let!(:transaction2) { create(:balance_transaction, user: user, purchase: purchase, balance: balance) }

      it 'detects duplicate balance increments' do
        service.reconcile
        expect(service.has_discrepancies?).to be true

        discrepancy = service.discrepancies.find { |d| d[:type] == :duplicate_balance_increment }
        expect(discrepancy).to be_present
        expect(discrepancy[:purchase]).to eq(purchase)
      end
    end

    context 'when balance transaction has no source' do
      let!(:balance) { create(:balance, user: user) }
      let!(:orphaned_transaction) do
        create(:balance_transaction,
               user: user,
               balance: balance,
               purchase: nil,
               dispute: nil,
               refund: nil,
               credit: nil)
      end

      it 'detects orphaned balance transaction' do
        service.reconcile
        expect(service.has_discrepancies?).to be true

        discrepancy = service.discrepancies.find { |d| d[:type] == :orphaned_balance_transaction }
        expect(discrepancy).to be_present
        expect(discrepancy[:balance_transaction]).to eq(orphaned_transaction)
      end
    end
  end

  describe '#auto_correct_discrepancies' do
    context 'with duplicate balance increment' do
      let!(:purchase) { create(:purchase, seller: user) }
      let!(:balance) { create(:balance, user: user, amount_cents: 2000, holding_amount_cents: 2000) }
      let!(:transaction1) do
        create(:balance_transaction,
               user: user,
               purchase: purchase,
               balance: balance,
               issued_amount_net_cents: 1000,
               holding_amount_net_cents: 1000)
      end
      let!(:transaction2) do
        create(:balance_transaction,
               user: user,
               purchase: purchase,
               balance: balance,
               issued_amount_net_cents: 1000,
               holding_amount_net_cents: 1000)
      end

      it 'corrects duplicate balance increment' do
        service.reconcile
        expect(service.has_discrepancies?).to be true

        service.auto_correct_discrepancies

        balance.reload
        expect(balance.amount_cents).to eq(1000)
        expect(balance.holding_amount_cents).to eq(1000)

        # One transaction should be soft deleted
        expect(purchase.balance_transactions.where(deleted_at: nil).count).to eq(1)
      end
    end

    context 'with balance calculation mismatch' do
      let!(:balance) { create(:balance, user: user, amount_cents: 1000, holding_amount_cents: 1000) }
      let!(:balance_transaction) do
        create(:balance_transaction,
               user: user,
               balance: balance,
               issued_amount_net_cents: 500,
               holding_amount_net_cents: 1000)
      end

      it 'corrects balance calculation mismatch' do
        service.reconcile
        expect(service.has_discrepancies?).to be true

        service.auto_correct_discrepancies

        balance.reload
        expect(balance.amount_cents).to eq(500)  # Corrected to match transaction
      end
    end
  end

  describe '.reconcile_all_users' do
    let!(:user1) { create(:user) }
    let!(:user2) { create(:user) }

    before do
      # Give users some balances so they show up in holding_balance scope
      create(:balance, user: user1, amount_cents: 100)
      create(:balance, user: user2, amount_cents: 200)
    end

    it 'reconciles all users with balances' do
      expect(described_class).to receive(:reconcile_user).with(user1, date: Date.current)
      expect(described_class).to receive(:reconcile_user).with(user2, date: Date.current)

      described_class.reconcile_all_users
    end
  end
end
