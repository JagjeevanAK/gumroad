# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BalanceIncrementRecord, type: :model do
  let(:purchase) { create(:purchase) }

  describe 'associations' do
    it { is_expected.to belong_to(:purchase) }
    it { is_expected.to belong_to(:balance_transaction).optional }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:purchase_id) }
    it { is_expected.to validate_uniqueness_of(:purchase_id) }
  end

  describe '.create_for_purchase!' do
    context 'when no record exists' do
      it 'creates a new record' do
        expect {
          BalanceIncrementRecord.create_for_purchase!(purchase)
        }.to change(BalanceIncrementRecord, :count).by(1)
      end

      it 'returns the created record' do
        record = BalanceIncrementRecord.create_for_purchase!(purchase)
        expect(record).to be_persisted
        expect(record.purchase).to eq(purchase)
      end
    end

    context 'when record already exists' do
      let!(:existing_record) { create(:balance_increment_record, purchase: purchase) }

      it 'does not create a new record' do
        expect {
          BalanceIncrementRecord.create_for_purchase!(purchase)
        }.not_to change(BalanceIncrementRecord, :count)
      end

      it 'returns the existing record' do
        record = BalanceIncrementRecord.create_for_purchase!(purchase)
        expect(record).to eq(existing_record)
      end
    end
  end

  describe '#mark_completed!' do
    let(:record) { create(:balance_increment_record, purchase: purchase) }
    let(:balance_transaction) { create(:balance_transaction) }

    it 'updates the balance_transaction association' do
      record.mark_completed!(balance_transaction)
      expect(record.reload.balance_transaction).to eq(balance_transaction)
    end
  end
end
