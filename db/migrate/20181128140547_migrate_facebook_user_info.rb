class MigrateFacebookUserInfo < ActiveRecord::Migration[5.2]
  def up
    execute <<~SQL
    INSERT INTO user_associated_accounts (
      provider_name,
      provider_uid,
      user_id,
      info,
      last_used,
      created_at,
      updated_at
    ) SELECT
      'facebook',
      facebook_user_id,
      user_id,
      json_build_object('email', email, 'first_name', first_name, 'last_name', last_name, 'name', name),
      updated_at,
      created_at,
      updated_at
    FROM facebook_user_infos
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
