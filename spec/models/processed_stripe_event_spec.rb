# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessedStripeEvent, type: :model do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:stripe_event_id) }
    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_uniqueness_of(:stripe_event_id) }
  end

  describe '.mark_processed!' do
    let(:stripe_event_id) { 'evt_test_123' }
    let(:event_type) { 'charge.succeeded' }
    let(:stripe_account_id) { 'acct_test_123' }
    let(:metadata) { { test: 'data' } }

    context 'when event has not been processed' do
      it 'creates a new record' do
        expect {
          ProcessedStripeEvent.mark_processed!(stripe_event_id, event_type)
        }.to change(ProcessedStripeEvent, :count).by(1)
      end

      it 'stores all provided data' do
        record = ProcessedStripeEvent.mark_processed!(
          stripe_event_id,
          event_type,
          stripe_account_id: stripe_account_id,
          metadata: metadata
        )

        expect(record.stripe_event_id).to eq(stripe_event_id)
        expect(record.event_type).to eq(event_type)
        expect(record.stripe_account_id).to eq(stripe_account_id)
        expect(record.metadata).to eq(metadata.stringify_keys)
      end
    end

    context 'when event has already been processed' do
      let!(:existing_record) do
        create(:processed_stripe_event, stripe_event_id: stripe_event_id)
      end

      it 'does not create a new record' do
        expect {
          ProcessedStripeEvent.mark_processed!(stripe_event_id, event_type)
        }.not_to change(ProcessedStripeEvent, :count)
      end

      it 'returns the existing record' do
        record = ProcessedStripeEvent.mark_processed!(stripe_event_id, event_type)
        expect(record).to eq(existing_record)
      end
    end
  end

  describe '.already_processed?' do
    let(:stripe_event_id) { 'evt_test_123' }

    context 'when event has been processed' do
      before { create(:processed_stripe_event, stripe_event_id: stripe_event_id) }

      it 'returns true' do
        expect(ProcessedStripeEvent.already_processed?(stripe_event_id)).to be true
      end
    end

    context 'when event has not been processed' do
      it 'returns false' do
        expect(ProcessedStripeEvent.already_processed?(stripe_event_id)).to be false
      end
    end
  end

  describe '.cleanup_old_events' do
    let!(:old_event) { create(:processed_stripe_event, created_at: 100.days.ago) }
    let!(:recent_event) { create(:processed_stripe_event, created_at: 10.days.ago) }

    it 'deletes events older than specified date' do
      expect {
        ProcessedStripeEvent.cleanup_old_events(90.days.ago)
      }.to change(ProcessedStripeEvent, :count).by(-1)

      expect(ProcessedStripeEvent.exists?(old_event.id)).to be false
      expect(ProcessedStripeEvent.exists?(recent_event.id)).to be true
    end

    it 'returns count of deleted events' do
      deleted_count = ProcessedStripeEvent.cleanup_old_events(90.days.ago)
      expect(deleted_count).to eq(1)
    end
  end
end
