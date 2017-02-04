ActiveRecord::Schema.define(version: 1) do
  create_table :typical_models, force: true do |t|
    t.string :name
    t.string :nickname
    t.string :team
    t.timestamps null: false
  end
end
