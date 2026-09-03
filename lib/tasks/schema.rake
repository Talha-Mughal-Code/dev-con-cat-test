# SQLite's structure dump includes `CREATE TABLE sqlite_sequence`, an internal
# table that cannot be created by hand - loading the dump emits a parse error on
# that line. Rails does not filter it, so we strip it after every dump.
#
# This only matters because the project uses the SQL schema format (see
# config/application.rb): the immutability triggers on consent_certificates and
# credit_ledger_entries cannot be expressed in a Ruby schema dump, and without
# them the test database would silently lack the guarantees the migrations exist
# to create.
STRIP_SQLITE_INTERNALS = lambda do
  Dir[Rails.root.join("db/*structure.sql")].each do |path|
    lines = File.readlines(path)
    kept = lines.reject { |line| line.start_with?("CREATE TABLE sqlite_sequence") }
    File.write(path, kept.join) if kept.length != lines.length
  end
end

%w[db:schema:dump db:migrate db:rollback].each do |name|
  Rake::Task[name].enhance { STRIP_SQLITE_INTERNALS.call } if Rake::Task.task_defined?(name)
end
