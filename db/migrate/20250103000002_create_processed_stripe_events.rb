# frozen_string_literal: true

class CreateProcessedStripeEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :processed_stripe_events do |t|
      t.string :stripe_event_id, null: false, limit: 255
      t.string :event_type, null: false, limit: 100
      t.string :stripe_account_id, limit: 255
      t.json :metadata
      t.timestamps null: false

      t.index :stripe_event_id, unique: true, name: 'idx_stripe_event_id'
      t.index [:event_type, :created_at], name: 'idx_event_type_created'
      t.index :stripe_account_id, name: 'idx_stripe_account'
    end
  end
end
