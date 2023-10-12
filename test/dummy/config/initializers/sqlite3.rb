module SqliteImmediateTransactions
  def begin_db_transaction
    log("begin immediate transaction", "TRANSACTION") do
      with_raw_connection(allow_retry: true, materialize_transactions: false) do |conn|
        conn.transaction(:immediate)
      end
    end
  end
end

module SQLite3Configuration
  private
    def configure_connection
      super

      if @config[:retries]
        retries = self.class.type_cast_config_to_integer(@config[:retries])
        raw_connection.busy_handler do |count|
          (count <= retries).tap { |result| sleep count * 0.001 if result }
        end
      end
    end
end

ActiveSupport.on_load :active_record do
  if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend SqliteImmediateTransactions
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend SQLite3Configuration
  end
end
