#!/usr/bin/env ruby

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rubygems'
require 'commander/import'
require 'rest-client'
require 'json'
require 'csv'
require 'yaml'
require 'qif'
require 'colorize'
require 'starling/export/version'

program :name, 'starling-export'
program :version, Starling::Export::VERSION
program :description, 'Generate QIF or CSV from Starling'

command :qif do |c|
  c.syntax = 'starling-export qif [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.option '--from STRING', String, 'The date (YYYY-MM-DD) to start exporting transactions from. Defaults to 2 weeks ago'
  c.option '--to STRING', String, 'The date (YYYY-MM-DD) to exporting transactions to. Defaults to today'
  c.action do |args, options|
    options.default directory: "#{File.dirname(__FILE__)}/exports"
    from = options.from ? Date.parse(options.from).to_time.strftime('%F') : (Time.now - (60*60*24*14)).to_date.strftime('%F')
    to = options.to ? Date.parse(options.to).to_time.strftime('%F') : Time.now.to_date.strftime('%F')
    path = "#{options.directory}/starling-#{from}-#{to}.qif"

    @access_token ||= options.access_token

    Qif::Writer.open(path, type = 'Bank', format = 'dd/mm/yyyy') do |qif|

      all_transactions = transactions(from, to)
      total_count = all_transactions.size

      all_transactions.reverse.each_with_index do |transaction, index|
        amount = (transaction['amount'].to_f).abs.to_s.ljust(6, ' ')
        amount_with_color = transaction['amount'] > 0 ? amount.green : amount.red

        puts "[#{(index + 1).to_s.rjust(total_count.to_s.length) }/#{total_count}] #{Date.parse(transaction['created']).to_s} - #{transaction['id']} - #{amount_with_color}  "

        qif << Qif::Transaction.new(
          date: DateTime.parse(transaction['created']).to_date,
          amount: transaction['amount'],
          status: transaction['status'] == "SETTLED" ? 'c' : nil,
          memo: "#{transaction['source']} - #{transaction['narrative']}",
          payee: transaction['narrative'],
          number: set_number(transaction),
          category: map_category(transaction),
        )
      end
    end

    puts ""
    puts "Exported to #{path}"
  end
end

command :csv do |c|
  c.syntax = 'starling-export csv [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.action do |args, options|
    @access_token ||= options.access_token
    options.default directory: "#{File.dirname(__FILE__)}/exports"
    path = "#{options.directory}/starling.csv"

    CSV.open(path, "wb") do |csv|
      csv << [:date, :description, :amount, :balance]

      all_transactions = transactions()
      total_count = all_transactions.size

      all_transactions.reverse.each_with_index do |transaction, index|

        amount = (transaction['amount'].to_f).abs.to_s.ljust(6, ' ')
        amount_with_color = transaction['amount'] > 0 ? amount.green : amount.red

        puts "[#{(index + 1).to_s.rjust(total_count.to_s.length) }/#{total_count}] #{Date.parse(transaction['created']).to_s} - #{transaction['id']} - #{amount_with_color}  "

        csv << [
          DateTime.parse(transaction['created']).strftime("%d/%m/%y"),
          transaction['narrative'],
          transaction['amount'],
          transaction['balance']
        ]
      end
    end

    puts ""
    puts "Exported to #{path}"
  end
end

command :balance do |c|
  c.syntax = 'starling-export balance [options]'
  c.summary = ''
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.action do |args, options|
    @access_token ||= options.access_token
    account_data = account()
    puts "Account Number: #{account_data['accountNumber']}"
    puts "Sort Code: #{account_data['sortCode']}"
    puts "Balance: £#{balance()}"
  end
end

def perform_request(path)
  url = "https://api.starlingbank.com/api/#{path}"
  JSON.parse(RestClient.get(url, {:Authorization => "Bearer #{@access_token}"}))
  #JSON.parse(RestClient::Request.execute(method: :get, url: url, headers: {:Authorization => "Bearer #{access_token}"}, timeout: 60))
end

def transactions(from, to)
  transactions = perform_request("v1/transactions?from=#{from}&to=#{to}")['_embedded']['transactions']
  transactions.map!{|t| get_extended_details(t)}
end

def balance
  perform_request("v1/accounts/balance")['availableToSpend']
end

def account
  perform_request("v1/accounts")
end

# TODO: this needs backoff handling as Starling throttle/block access after an
# undetermined number of quick successive API requests.
def get_extended_details(txn)
  path = case txn['source']
      when 'MASTER_CARD' then 'mastercard'
      when 'FASTER_PAYMENTS_IN', 'FASTER_PAYMENTS_OUT' then "fps/#{txn['source'].split('_').last.downcase}"
      when 'DIRECT_DEBIT' then 'direct-debit'
      else nil
    end
  path.nil? ? txn : perform_request("v1/transactions/#{path}/#{txn['id']}")
end

# WARNING: This uses the unstable v2 API so will probably break at some point
def get_extended_details_v2(txn)
  account_id = account()
end

def set_number(txn)
  return 'Online' if txn['mastercardTransactionMethod'] == 'ONLINE'
  return 'ATM' if txn['mastercardTransactionMethod'] == 'ATM'
  return 'Transfer' if txn['source'] == 'INTERNAL_TRANSFER'
  return 'Deposit' if txn['amount'] > 0
  return 'POS'
end

def map_category(txn)
    return nil unless txn['spendingCategory']
    cat = txn['spendingCategory']

    category_map = {
      'BILLS_AND_SERVICES'  => nil,
      'EATING_OUT'          => 'Dining:Restaurants',
      'ENTERTAINMENT'       => 'Entertainment',
      'EXPENSES'            => 'Work Expenses',
      'GENERAL'             => nil,
      'GIFTS'               => 'Gifts',
      'GROCERIES'           => 'Groceries',
      'SHOPPING'            => 'Clothing',
      'HOLIDAYS'            => 'Travel',
      'PAYMENTS'            => nil,
      'TRANSPORT'           => 'Travel',
      'LIFESTYLE'           => nil,
    }

    return category_map[cat] if category_map.include?(cat)
    return 'ATM' if txn['mastercardTransactionMethod'] == 'ATM'
    return 'Interest Received' if txn['mastercardTransactionMethod'] == 'INTEREST_PAYMENT'

    nil
  end
