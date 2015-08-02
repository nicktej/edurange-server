class CreateStatistics < ActiveRecord::Migration
  def change
    create_table :statistics do |t|
      t.belongs_to :user
      t.timestamps null: false
      t.string :bash_histories
      
      t.text :bash_analytics
      t.string :scenario_name
      t.datetime :scenario_created_at	
    end
  end
end