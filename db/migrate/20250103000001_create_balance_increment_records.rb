# frozen_string_literal: true

class CreateBalanceIncrementRecords < ActiveRecord::Migration[7.0]
  def change
    create_table :balance_increment_records do |t|
      t.bigint :purchase_id, null: false
      t.bigint :balance_transaction_id, null: true
      t.timestamps null: false

      t.index :purchase_id, unique: true, name: 'idx_purchase_balance_increment'
      t.index :balance_transaction_id, name: 'idx_balance_transaction'
    end

    add_foreign_key :balance_increment_records, :purchases, column: :purchase_id
    add_foreign_key :balance_increment_records, :balance_transactions, column: :balance_transaction_id
  end
end
