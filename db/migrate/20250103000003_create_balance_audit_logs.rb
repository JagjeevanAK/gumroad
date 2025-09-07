# frozen_string_literal: true

class CreateBalanceAuditLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :balance_audit_logs do |t|
      t.bigint :balance_id, null: false
      t.string :operation, null: false, limit: 50
      t.bigint :amount_cents_before
      t.bigint :amount_cents_after
      t.bigint :holding_amount_cents_before
      t.bigint :holding_amount_cents_after
      t.string :triggered_by, limit: 100
      t.string :source_type, limit: 50
      t.bigint :source_id
      t.json :metadata
      t.timestamps null: false

      t.index :balance_id, name: 'idx_balance_audit_balance'
      t.index [:operation, :created_at], name: 'idx_operation_created'
      t.index [:source_type, :source_id], name: 'idx_source'
      t.index :created_at, name: 'idx_created_at'
    end

    add_foreign_key :balance_audit_logs, :balances, column: :balance_id
  end
end
