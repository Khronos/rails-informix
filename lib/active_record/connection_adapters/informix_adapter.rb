# Copyright (c) 2006-2010, Gerardo Santana Gomez Garrido <gerardo.santana@gmail.com>
# Rails 3.2 additions by Martin Little (khronos@github) 
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. The name of the author may not be used to endorse or promote products
#    derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/statement_pool'
require 'arel/visitors/bind_visitor'
#We're going to hack around the state of the informix visitor for now.
require 'arel/visitors/informix'

module ActiveRecord
  class Base
    def self.informix_connection(config) #:nodoc:
      config = config.symbolize_keys
      #Force informix to speak rails date format unless otherwise requested
      #This solves a number of compatability problems that will otherwise surface
      ENV['DBDATE'] = config[:date_format] || 'Y4MD-' 

      require 'informix' unless self.class.const_defined?(:Informix)
      require 'stringio'
      

      database    = config[:database].to_s
      username    = config[:username]
      password    = config[:password]
      db          = Informix.connect(database, username, password)
      ConnectionAdapters::InformixAdapter.new(db, logger, config)
    end

    after_save :write_lobs
    private
      def write_lobs
        return if !connection.is_a?(ConnectionAdapters::InformixAdapter)
        self.class.columns.each do |c|
          value = self[c.name]
          next if ![:text, :binary].include? c.type 
          
          unless value.nil? || (value == '')
#            Rails.logger.warn("Writing lob: #{c.type} : #{value}")
            connection.raw_connection.execute(<<-end_sql, StringIO.new(value))
              UPDATE #{self.class.table_name} SET #{c.name} = ?
              WHERE #{self.class.primary_key} = #{quote_value(id)}
          end_sql
          end
        end
      end
  end # class Base
    


  module ConnectionAdapters
    class InformixColumn < Column
      def initialize(column)
        sql_type = make_type(column[:stype], column[:length],
                             column[:precision], column[:scale], 
                             column[:xid])
        super(column[:name], column[:default], sql_type, column[:nullable])
      end
      def adapter
        InformixAdapter
      end

      private
        IFX_TYPES_SUBSET = %w(CHAR CHARACTER CHARACTER\ VARYING DECIMAL FLOAT
                              LIST LVARCHAR MONEY MULTISET NCHAR NUMERIC
                              NVARCHAR SERIAL SERIAL8 VARCHAR).freeze

        def make_type(type, limit, prec, scale, extended)
          type.sub!(/money/i, 'DECIMAL')
          if IFX_TYPES_SUBSET.include? type.upcase
            if prec == 0
              "#{type}(#{limit})" 
            else
              "#{type}(#{prec},#{scale})"
            end
          elsif type =~ /datetime/i
            type = "time" if prec == 6
            type
          elsif type =~ /byte/i
            "binary"
          elsif type =~ /VARIABLE-LENGTH OPAQUE TYPE/ && extended == 5
            "boolean"
          else
            type
          end
        end

        def simplified_type(sql_type)
          if sql_type =~ /serial/i
#            :primary_key
            :integer
          else
            super
          end
        end
    end




    # This adapter requires Ruby/Informix
    # http://ruby-informix.rubyforge.org
    #
    # Options:
    #
    # * <tt>:database</tt>  -- Defaults to nothing.
    # * <tt>:username</tt>  -- Defaults to nothing.
    # * <tt>:password</tt>  -- Defaults to nothing.

    class InformixAdapter < AbstractAdapter
      def initialize(db, logger, config)
        super(db, logger)
        @ifx_version = db.version.major.to_i

        @quoted_column_names, @quoted_table_names = {}, {}

#        if config.fetch(:prepared_statements) { true }
          @visitor = Arel::Visitors::Informix.new self
#        else
#          @visitor = BindSubstitution.new self
#        end

      end

      def native_database_types
        {
          :primary_key => "serial primary key",
          :string      => { :name => "varchar", :limit => 255  },
          :text        => { :name => "text" },
          :integer     => { :name => "integer" },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime year to second" },
          :timestamp   => { :name => "datetime year to second" },
          :time        => { :name => "datetime hour to second" },
          :date        => { :name => "date" },
          :binary      => { :name => "byte"},
          :boolean     => { :name => "boolean"}
        }
      end
      
      attr_reader :last_arel
      @last_arel = nil
      def to_sql(arel, binds=[])
        @last_arel = arel
        super(arel, binds)
      end

      def adapter_name
        'Informix'
      end

      def supports_migrations? #:nodoc:
        true
      end

      def supports_primary_key?
        true
      end

      def supports_count_distinct?
        true
      end

      def supports_ddl_transactions?
        true
      end
      
      def supports_bulk_alter?
        true
      end

      def supports_savepoints?
        true
      end

      #Used to support sequence tables
      #Requires next_sequence_value
      def prefetch_primary_key?(table_name = nil)
        true
      end
      def default_sequence_name(table, column) #:nodoc:
        "#{table}_seq"
      end

      def supports_index_sort_order?
        true
      end
      
      #Verify this, might have to change the ruby-informix code 
      def supports_explain?
        true
      end
 
      #TODO - Add support for this
      def supports_statement_cache?
        false
      end

      # QUOTING ===========================================
      def quote_string(string)
        string.gsub(/\'/, "''")
      end

      def quote(value, column = nil)
        if column && [:binary, :text].include?(column.type)
          return "NULL"
        end
        super
      end

      def quote_column_name(name) #:nodoc:
        @quoted_column_names[name] ||= "#{name.to_s.gsub('\'', '\'\'')}"
      end

      def quote_table_name(name) #:nodoc:
        @quoted_table_names[name] ||= quote_column_name(name).gsub('.', '`.`')
      end

      def quoted_date(value)
        super
      end

      def quoted_true
        %Q{'t'}
      end

      def quoted_false
        %Q{'f'}
      end

      # REFERENTIAL INTEGRITY ====================================

      # Override to turn off referential integrity while executing <tt>&block</tt>.
      # TODO: Will probably need to implement this
      #def disable_referential_integrity
      #  yield
      #end

      # CONNECTION MANAGEMENT ====================================
      # Reset the state of this connection, directing the DBMS to clear
      # transactions and other connection-related server-side state. Usually a
      # database-dependent operation.
      #
      # The default implementation does nothing; the implementation should be
      # overridden by concrete adapters.
      def reset!
        # this should be overridden by concrete adapters
      end

      ###
      # Clear any caching the database adapter may be doing, for example
      # clearing the prepared statement cache. This is database specific.
      def clear_cache!
        # this should be overridden by concrete adapters
      end

      # Returns true if its required to reload the connection between requests for development mode.
      # This is not the case for Ruby/MySQL and it's not necessary for any adapters except SQLite.
      def requires_reloading?
        false
      end

      # Checks whether the connection to the database is still active (i.e. not stale).
      # This is done under the hood by calling <tt>active?</tt>. If the connection
      # is no longer active, then this method will reconnect to the database.
      def verify!(*ignored)
        reconnect! unless active?
      end

      # Provides access to the underlying database driver for this adapter. For
      # example, this method returns a Mysql object in case of MysqlAdapter,
      # and a PGconn object in case of PostgreSQLAdapter.
      #
      # This is useful for when you need to call a proprietary method such as
      # PostgreSQL's lo_* methods.
      def raw_connection
        @connection
      end

      #TODO
      def create_savepoint
      end

      #TODO
      def rollback_to_savepoint
      end

      #TODO
      def release_savepoint
      end


      class BindSubstitution < Arel::Visitors::Informix # :nodoc:
        include Arel::Visitors::BindVisitor
      end
      

      # DATABASE STATEMENTS =====================================
      def select(sql, name = nil, binds = [])
        c = log(sql, name) { @connection.cursor(sql) }
        rows = c.open.fetch_hash_all
        c.free
        rows
      end

      def select_rows(sql, name = nil)
        c = log(sql, name) { @connection.cursor(sql) }
        rows = c.open.fetch_all
        c.free
        rows
      end

      def execute(sql, name = nil)
        log(sql, name) { @connection.immediate(sql) }
      end

      def exec_query(sql, name = 'SQL', binds = [])
        c = log(sql, name) { @connection.cursor(sql, :params => binds) }
        rows = c.open.fetch_all
        c.free
        rows
      end

      def prepare(sql, name = nil)
        log(sql, name) { @connection.prepare(sql) }
      end

      def insert(sql, name= nil, pk= nil, id_value= nil, sequence_name = nil)
        execute(sql)
        id_value
      end

      alias_method :update, :execute
      alias_method :delete, :execute

      def begin_db_transaction
        execute("begin work")
      end

      def commit_db_transaction
        @connection.commit
      end

      def rollback_db_transaction
        @connection.rollback
      end

      def add_limit_offset!(sql, options)
        if options[:limit]
          limit = "FIRST #{options[:limit]}"
          # SKIP available only in IDS >= 10
          offset = @ifx_version >= 10 && options[:offset]? "SKIP #{options[:offset]}": ""
          sql.sub!(/^select /i,"SELECT #{offset} #{limit} ")
        end
        sql
      end

      def next_sequence_value(sequence_name)
        select_one("select #{sequence_name}.nextval id from systables where tabid=1")['id']
      end


      # SCHEMA STATEMENTS =====================================
      def tables(name = nil)
        @connection.cursor(<<-end_sql) do |cur|
            SELECT tabname FROM systables WHERE tabid > 99 AND tabtype != 'Q'
          end_sql
          cur.open.fetch_all.flatten
        end
      end

      def columns(table_name, name = nil)
        @connection.columns(table_name).map {|col| InformixColumn.new(col) }
      end

      # MIGRATION =========================================
      def recreate_database(name)
        drop_database(name)
        create_database(name)
      end

      def drop_database(name)
        execute("drop database #{name}")
      end

      def create_database(name)
        execute("create database #{name}")
      end

      # XXX
      def indexes(table_name, name = nil)
        indexes = []
      end
            
      def create_table(name, options = {})
        super(name, options)
        execute("CREATE SEQUENCE #{name}_seq")
      end

      def rename_table(name, new_name)
        execute("RENAME TABLE #{name} TO #{new_name}")
        execute("RENAME SEQUENCE #{name}_seq TO #{new_name}_seq")
      end

      def drop_table(name)
        super(name)
        execute("DROP SEQUENCE #{name}_seq")
      end
      
      def rename_column(table, column, new_column_name)
        execute("RENAME COLUMN #{table}.#{column} TO #{new_column_name}")
      end
      
      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        sql = "ALTER TABLE #{table_name} MODIFY #{column_name} #{type_to_sql(type, options[:limit])}"
        add_column_options!(sql, options)
        execute(sql)
      end

      def remove_index(table_name, options = {})
        execute("DROP INDEX #{index_name(table_name, options)}")
      end

      # XXX
      def structure_dump
        super
      end

      def structure_drop
        super
      end

      def primary_key(table)
        #From a forum post about obtaining primary key in informix
        #http://www.dbforums.com/informix/1622533-how-get-primary-key.html
        sql=<<PK_QUERY
        select colname 
        from systables a, sysconstraints b, sysindexes c , syscolumns d
        where a.tabname = "#{table}"
        and a.tabid = b.tabid
        and a.tabid = c.tabid 
        and a.tabid = d.tabid
        and b.constrtype ='P'
        and b.idxname = c.idxname
        and ( 
          colno = part1 or 
          colno = part2 or 
          colno = part3 or 
          colno = part4 or
          colno = part5 or
          colno = part6 or
          colno = part7 or
          colno = part8 or
          colno = part9 or
          colno = part10 or
          colno = part11 or
          colno = part12 or
          colno = part13 or
          colno = part14 or
          colno = part15 or
          colno = part16 
          )
PK_QUERY

        @connection.cursor(sql) do |cur|
          cur.open.fetch_all.flatten
        end
      end
      
      
      private
    end #class InformixAdapter < AbstractAdapter
  end #module ConnectionAdapters
end #module ActiveRecord

module Arel
  module Visitors
    class Informix
      undef :visit_Arel_Nodes_SelectStatement
      def visit_Arel_Nodes_SelectStatement o
        [
          "SELECT",
          (visit(o.offset) if o.offset),
          (visit(o.limit) if o.limit),
          (visit(o.with) if o.with),
          o.cores.map { |x| visit_Arel_Nodes_SelectCore x }.join,
          ("ORDER BY #{o.orders.map { |x| visit x }.join(', ')}" unless o.orders.empty?),
          (visit(o.lock) if o.lock)
        ].compact.join ' '
      end

      undef :visit_Arel_Nodes_SelectCore
      def visit_Arel_Nodes_SelectCore o
        [
          (visit(o.top) if o.top),
          (visit(o.set_quantifier) if o.set_quantifier),
          ("#{o.projections.map { |x| visit x }.join ', '}" unless o.projections.empty?),
          ("FROM #{visit(o.source)}" if o.source && !o.source.empty?),
          ("WHERE #{o.wheres.map { |x| visit x }.join ' AND ' }" unless o.wheres.empty?),
          ("GROUP BY #{o.groups.map { |x| visit x }.join ', ' }" unless o.groups.empty?),
          (visit(o.having) if o.having)
        ].compact.join ' '
      end
    end
  end
end
