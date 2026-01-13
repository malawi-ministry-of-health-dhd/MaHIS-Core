db_config = YAML.load_file(Rails.root.join('config', 'database.yml'), aliases: true)[Rails.env]
username = db_config['username']
password = db_config['password']
database = db_config['database']

cmd = "gunzip -c db/mahis_skeleton.sql.gz | mysql -u #{username}"
cmd += " -p#{password}" if password.present?
cmd += " #{database}"

system(cmd)
puts 'Hamornized db Initialization Complete 🎉'
