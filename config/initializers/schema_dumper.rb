# Strip schema prefix from PostgreSQL extensions in schema.rb
# This ensures extensions are dumped as "plpgsql" instead of "pg_catalog.plpgsql"
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(Module.new do
    def extensions
      super.map { |ext| ext.gsub(/^pg_catalog\./, "") }
    end
  end)
end
