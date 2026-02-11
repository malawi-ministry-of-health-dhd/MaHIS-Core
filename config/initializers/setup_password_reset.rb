# frozen_string_literal: true

# frozen_string_literal: true

file_path = Rails.root.join('config/application.yml')

# remove -e from the application.yml if present
if File.exist?(file_path)
  content = File.read(file_path)
  if content.match?(/^-e\s*$/)
    new_content = content.gsub(/^-e\s*$\n?/, '')
    File.write(file_path, new_content)
  end
end

if File.exist?(file_path) &&
   File.read(file_path).include?('password_reset')
  return
end

File.open(file_path, 'a') do |f|
  f.puts "\npassword_reset:"
  f.puts "  secret_key: CENTRALISED-EMR"
end
